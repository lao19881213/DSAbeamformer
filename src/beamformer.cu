#include "beamformer.cuh"

// nvcc src/beamformer.cu -o bin/beam -lcublas

int main(){
	std::cout << "Executing beamformer.cu" << std::endl;
	print_all_defines();



	/* CUBLAS Dimensions */
	int A_rows	 = N_BEAMS;
	int A_cols 	 = N_ANTENNAS;
	int A_stride = A_rows*A_cols;
	int B_cols	 = N_TIMESTEPS_PER_GEMM;
	int B_rows	 = A_cols;
	int B_stride = B_rows*B_cols;
	int C_rows	 = A_rows;
	int C_cols	 = B_cols;
	int C_stride = C_rows*C_cols;
	float bw_per_channel = BW_PER_CHANNEL; 

	/***********************************
	 *			GPU Variables		   *
	 ***********************************/
	CxInt8_t *d_A; 				// Weight matrix (N_BEAMS X N_ANTENNAS, for N_FREQUENCIES)
	CxInt8_t *d_B; 				// Data Matrix (N_ANTENNAS X N_TIMESTEPS_PER_GEMM, for N_FREQUENCIES)
	char *d_data;				// Raw input data (Before data massaging)
	cuComplex *d_C;				// Beamformed output (N_BEAMS X N_TIMESTEPS_PER_GEMM, for N_FREQUENCIES)
	float *d_out;				// Data after being averaged over 16 time samples and 2 polarizations

	/* CUBLAS Constants */
	cuComplex  h_inv_max_value,  h_zero; 		//Host Values
	cuComplex *d_inv_max_value, *d_zero; 	//Device Values

	h_inv_max_value.x = 1.0/MAX_VAL;
	h_inv_max_value.y = 0;
	h_zero.x = 0;
	h_zero.y = 0;

	#if DEBUG
		float  h_f_one,  h_f_zero;				//Host Values
		float *d_f_one, *d_f_zero;				//Device Values	
		h_f_one = 1.0;
		h_f_zero = 0.0;
	#endif

	/***********************************
	 *			HOST Variables		   *
	 ***********************************/
	CxInt8_t *A = new CxInt8_t[A_cols*A_rows*N_FREQUENCIES];
	char *data = new char[(long) N_BYTES_PRE_EXPANSION_PER_GEMM*N_DIRS];
	float *beam_out = new float[N_F_PER_DETECT*N_STREAMS];
	gpuErrchk(cudaHostRegister(data, (long) N_BYTES_PRE_EXPANSION_PER_GEMM*N_DIRS*sizeof(char), cudaHostRegisterPortable)); //need pinned memory
	gpuErrchk(cudaHostRegister(beam_out, N_FREQUENCIES*N_BEAMS*N_OUTPUTS_PER_GEMM*N_STREAMS*sizeof(float), cudaHostRegisterPortable)); //need pinned memory



	#if DEBUG
		std::cout << "data size: " << N_BYTES_PRE_EXPANSION_PER_GEMM*N_DIRS << std::endl;
		std::ofstream f;
		f.open("bin/data.py");
		f << "A = [[";
		std::mutex file_mutex;

		float *d_dedispersed;	// Data after being de-dispersed
		float *d_vec_ones;		// Vector of all ones for de-dispersion
		float *out_dedispersed = new float[N_BEAMS*N_STREAMS];
		float *vec_ones = new float[N_FREQUENCIES];
		gpuErrchk(cudaHostRegister(out_dedispersed, N_BEAMS*N_STREAMS*sizeof(float), cudaHostRegisterPortable));

	#endif

	/***********************************
	 *		Beamforming Variables	   *
	 ***********************************/
	float* pos = new float[N_ANTENNAS];		// Locations of antennas
	float* dir = new float[N_BEAMS];		// Direction of bemformed beams
	int gpu = 0;							// Unique identifier for each GPU

	/* Populate location/direction Matricies */
	for (int i = 0; i < N_ANTENNAS; i++){
		pos[i] = i*500.0/(N_ANTENNAS-1) - 250.0;
	}

	/* Directions for Beamforming */
	for (int i = 0; i < N_BEAMS; i++){
		dir[i] = i*DEG2RAD(7.0)/(N_BEAMS-1) - DEG2RAD(3.5);
	}

	/* Create vector of ones for Dedispersion */
	#if DEBUG
		for (int i = 0; i < N_FREQUENCIES; i++){
			vec_ones[i] = 1.0;
		}
	#endif


	/* Fourier Coefficient Matrix */
	for (int i = 0; i < N_FREQUENCIES; i++){
		float freq = END_F - (ZERO_PT + gpu*TOT_CHANNELS/(N_GPUS-1) + i)*bw_per_channel;
		float wavelength = C_SPEED/(1E9*freq);
		for (int j = 0; j < N_ANTENNAS; j++){
			for (int k = 0; k < N_BEAMS; k++){
				A[i*A_stride + j*N_BEAMS + k].x = round(MAX_VAL*cos(-2*PI*pos[j]*sin(dir[k])/wavelength));
				A[i*A_stride + j*N_BEAMS + k].y = round(MAX_VAL*sin(-2*PI*pos[j]*sin(dir[k])/wavelength));
			}
		}
	}


	/***********************************
	 *			Memory Allocation 	   *
	 ***********************************/
	gpuErrchk(cudaMalloc(&d_A, 	A_rows*A_cols*N_FREQUENCIES*sizeof(CxInt8_t)));
	gpuErrchk(cudaMalloc(&d_B, 	N_CX_IN_PER_GEMM*N_STREAMS*sizeof(CxInt8_t)));
	gpuErrchk(cudaMalloc(&d_C, 	N_CX_OUT_PER_GEMM*N_STREAMS*sizeof(cuComplex)));
	gpuErrchk(cudaMalloc(&d_data, N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK*N_BLOCKS_on_GPU)); 							// array for raw data
	gpuErrchk(cudaMalloc(&d_out, N_F_PER_DETECT*N_STREAMS * sizeof(float)));			// array for detected, averaged data

	/* Cublas Constant Memory */
	gpuErrchk(cudaMalloc(&d_inv_max_value, sizeof(cuComplex)));
	gpuErrchk(cudaMalloc(&d_zero, sizeof(cuComplex)));


	#if DEBUG
		gpuErrchk(cudaMalloc(&d_f_one, sizeof(float)));
		gpuErrchk(cudaMalloc(&d_f_zero, sizeof(float)));
		gpuErrchk(cudaMalloc(&d_dedispersed, N_BEAMS*N_STREAMS*sizeof(float)));						// array for frequency averaged data
		gpuErrchk(cudaMalloc(&d_vec_ones, N_FREQUENCIES*sizeof(float)));
	#endif

	/* Copy constants to memory */
	gpuErrchk(cudaMemcpy(d_A, A, A_rows*A_cols*N_FREQUENCIES*sizeof(CxInt8_t), cudaMemcpyHostToDevice));
	gpuErrchk(cudaMemcpy(d_inv_max_value, &h_inv_max_value, sizeof(cuComplex), cudaMemcpyHostToDevice));
	gpuErrchk(cudaMemcpy(d_zero, &h_zero, sizeof(cuComplex), cudaMemcpyHostToDevice));


	#if DEBUG
		gpuErrchk(cudaMemcpy(d_vec_ones, vec_ones, N_FREQUENCIES*sizeof(float), cudaMemcpyHostToDevice));
		gpuErrchk(cudaMemcpy(d_f_one, &h_f_one, sizeof(float), cudaMemcpyHostToDevice));
		gpuErrchk(cudaMemcpy(d_f_zero, &h_f_zero, sizeof(float), cudaMemcpyHostToDevice));
		std::cout << "First: " << h_f_zero << " and " << h_f_one << std::endl;
		print_data_scalar<<<1, 1>>>(d_f_one);
		print_data_scalar<<<1, 1>>>(d_f_zero);
	#endif

	// gpuErrchk(cudaMemset(d_dedispersed, 0, N_BEAMS*N_STREAMS*sizeof(float)));

	/***********************************
	 *		Concurrency Handles		   *
	 ***********************************/
	cudaStream_t stream[N_STREAMS];
	cublasHandle_t handle[N_STREAMS];
	std::thread thread[N_STREAMS];
	int timeSlice[N_STREAMS];
	cudaEvent_t BlockSync[N_BLOCKS_on_GPU];

	for (int i = 0; i < N_STREAMS; i++){
		gpuErrchk(cudaStreamCreate(&(stream[i])));
		gpuBLASchk(cublasCreate(&handle[i]));
		gpuBLASchk(cublasSetStream(handle[i], stream[i]));
		gpuBLASchk(cublasSetPointerMode(handle[i], CUBLAS_POINTER_MODE_DEVICE));
		timeSlice[i] = i;
	}

	for (int i = 0; i < N_BLOCKS_on_GPU; i++){
		cudaEventCreate(&BlockSync[i]);
	}

	/***********************************
	 *			TEST SIGNAL			   *
	 ***********************************/


	#if DEBUG
	float test_direction;
	char high, low;
	for (int iii = 0; iii < N_DIRS; iii++){
		test_direction = DEG2RAD(-3.5) + iii*DEG2RAD(7.0)/(N_DIRS-1);
		for (int i = 0; i < N_FREQUENCIES; i++){
			float freq = END_F - (ZERO_PT + gpu*TOT_CHANNELS/(N_GPUS-1) + i)*BW_PER_CHANNEL;
			// std::cout << "freq: " << freq << std::endl;
			float wavelength = C_SPEED/(1E9*freq);
			for (int j = 0; j < N_TIMESTEPS_PER_GEMM; j++){
				for (int k = 0; k < N_ANTENNAS; k++){

					high = ((char) round(SIG_MAX_VAL*cos(2*PI*pos[k]*sin(test_direction)/wavelength))); //real
					low  = ((char) round(SIG_MAX_VAL*sin(2*PI*pos[k]*sin(test_direction)/wavelength))); //imag

					data[iii*N_BYTES_PRE_EXPANSION_PER_GEMM + i*B_stride + j*N_ANTENNAS + k] = (high << 4) | (0x0F & low);
				}
			}
		}
	}
	#else
	memset(data, 0x70, N_BYTES_PRE_EXPANSION_PER_GEMM*N_DIRS*sizeof(char));
	std::cout << "BOGUS DATA " << std::endl;
	#endif

	std::cout << "done writing data" << std::endl;

	int observation_complete = 0;
	int64_t blocks_analyzed = 0;
	int current_gemm = 0;
	int64_t blocks_transfered = 0;


	while (!observation_complete){
		
		// std::cout << "hello1" << std::endl;

		// if (blocks_analyzed == blocks_transfered){
		// 	gpuErrchk(cudaMemcpy(&(d_data[N_BYTES_PER_BLOCK*(blocks_transfered%N_BLOCKS_on_GPU)]),
		// 						 &data[N_BYTES_PER_BLOCK*(blocks_transfered%N_DIRS)],
		// 						 cudaMemcpyHostToDevice));
		// } elseif(blocks_analyzed < blocks_transfered){
		// 	for (int i = 0; i < N_GEMMS_PER_GPU; ++i){

		// 	}
		// 	blocks_analyzed ++;
		// }

	 	
		// int simulated_direction = 100;
		// int tot_avging = N_POL*N_AVERAGING;



		// std::cout << "hello2" << std::endl;

		// cudaMemcpy(d_B, B, B_rows*B_cols*N_FREQUENCIES*sizeof(CxInt8_t), cudaMemcpyHostToDevice);

		// The following IF statements are not mutually exclusive
		if (blocks_analyzed == blocks_transfered){

			std::cout << "sindex: " << N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK*(blocks_transfered%N_BLOCKS_on_GPU) << std::endl;
			std::cout << "sindex: " << N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK*(blocks_transfered%N_DIRS) << std::endl;
			std::cout << "sindex: " << N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK << std::endl;

			// wait for data to be ready
			gpuErrchk(cudaMemcpy(&(d_data[N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK*(blocks_transfered%N_BLOCKS_on_GPU)]), 
										&(data[N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK*(blocks_transfered%(N_DIRS/N_GEMMS_PER_BLOCK))]),
										N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK, 
										cudaMemcpyHostToDevice));



			blocks_transfered++;

			std::cout << "Analyzed == Transfered, Synchronous copy" << std::endl;
			std::cout << "Transfered: " << blocks_transfered << " Analyzed: " <<blocks_analyzed << std::endl;
		}

		if (blocks_analyzed == blocks_transfered-1){

			std::cout << "index: " << N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK*(blocks_transfered%N_BLOCKS_on_GPU) << std::endl;
			std::cout << "index: " << N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK*(blocks_transfered%(N_DIRS/N_GEMMS_PER_BLOCK)) << std::endl;
			std::cout << "index: " << N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK << std::endl;

			// do not wait for data to be ready
			gpuErrchk(cudaMemcpyAsync(&d_data[N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK*(blocks_transfered%N_BLOCKS_on_GPU)], 
										&data[N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK*(blocks_transfered%(N_DIRS/N_GEMMS_PER_BLOCK))],
										N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK, 
										cudaMemcpyHostToDevice,
										stream[0]));

			// gpuErrchk(cudaEventRecord(BlockSync[blocks_transfered%N_BLOCKS_on_GPU], HtoD_stream));

			blocks_transfered++;
			std::cout << "Surplus of blocks, Asynchronous copy" << std::endl;
			std::cout << "Transfered: " << blocks_transfered << " Analyzed: " <<blocks_analyzed << std::endl;

		}
		// std::cout << "hello2a" << std::endl;
		
		if (blocks_analyzed < blocks_transfered){

			for (int st = 0; st < N_STREAMS; st++){
				current_gemm = blocks_analyzed*N_GEMMS_PER_BLOCK + timeSlice[st];

				if (current_gemm % 100 == 0){
					std::cout << "Direction: " << current_gemm << std::endl;
				}

				//cudaStreamSynchronize(stream[st]);

				expand_input<<<1000, 32, 0, stream[st]>>>(&d_data[N_BYTES_PRE_EXPANSION_PER_GEMM*(N_GEMMS_PER_BLOCK*(blocks_analyzed%N_BLOCKS_on_GPU) + timeSlice[st])],
													      (char *) &d_B[N_CX_IN_PER_GEMM*st], 
													      B_stride*N_FREQUENCIES);

				// std::cout << "hello2b" << std::endl;
				gpuBLASchk(cublasGemmStridedBatchedEx(handle[st], CUBLAS_OP_N, CUBLAS_OP_N,
											A_rows, B_cols, A_cols,
											d_inv_max_value,
											d_A, CUDA_C_8I, A_rows, A_stride,
											&d_B[N_CX_IN_PER_GEMM*st], CUDA_C_8I, B_rows, B_stride,
											d_zero,
											&d_C[N_CX_OUT_PER_GEMM*st], CUDA_C_32F, C_rows, C_stride,
											N_FREQUENCIES, CUDA_C_32F, CUBLAS_GEMM_DEFAULT_TENSOR_OP));

				// std::cout << "hello3" << std::endl;
				detect_sum<<<detect_dimGrid, detect_dimBlock, 0, stream[st]>>>(&d_C[N_CX_OUT_PER_GEMM*st], N_INPUTS_PER_OUTPUT, &d_out[st*N_F_PER_DETECT]);

				gpuErrchk(cudaMemcpyAsync(&beam_out[st*N_F_PER_DETECT], 
										  &d_out[st*N_F_PER_DETECT], N_OUTPUTS_PER_GEMM*N_FREQUENCIES*N_BEAMS*sizeof(float), 
										  cudaMemcpyDeviceToHost,
										  stream[st]));


				#if DEBUG
					gpuErrchk(cudaStreamSynchronize(stream[st]));
					// std::cout << "hello4" << std::endl;
					std::cout << " test data: " << beam_out[st*N_F_PER_DETECT] << std::endl;
					std::cout << " test data: " << beam_out[st*N_F_PER_DETECT+1] << std::endl;
					std::cout << " test data: " << beam_out[st*N_F_PER_DETECT+2] << std::endl;

					#if 0
					for (int j = 0; j < N_BEAMS; j++){
						float ans = 0;
						for (int i = 0; i < N_FREQUENCIES; i ++){
							ans += beam_out[st*N_F_PER_DETECT + i*N_BEAMS + j];
						}
						// std::cout << "ans = " << ans << std::endl;
						f << ans;
						if (j != N_BEAMS - 1){
							f << ",";
						}
					}

					if (current_gemm != N_DIRS-1){
						f << "],\n[";
					} else {
						f<< "]]"<<std::endl;
					}
					#else
					// std::cout << "First:" << std::endl;
					// print_data_scalar<<<1, 1,0, stream[st]>>>(d_f_one);
					// print_data_scalar<<<1, 1,0, stream[st]>>>(d_f_zero);


					print_data<<<1, 10,0, stream[st]>>>(&d_out[st*N_F_PER_DETECT]);
					gpuBLASchk(cublasSgemv(handle[st], CUBLAS_OP_N,
								N_BEAMS, N_FREQUENCIES,
								d_f_one,
								&d_out[st*N_F_PER_DETECT], N_BEAMS,
								d_vec_ones, 1,
								d_f_zero,
								&d_dedispersed[st*N_BEAMS], 1));

					// gpuErrchk(cudaStreamSynchronize(stream[st]));
					std::cout << "Second:" << std::endl;
					print_data<<<1, 10>>>(&d_dedispersed[st*N_BEAMS]);
					gpuErrchk(cudaMemcpyAsync(&out_dedispersed[st*N_BEAMS], 
											  &d_dedispersed[st*N_BEAMS], N_BEAMS*sizeof(float), 
											  cudaMemcpyDeviceToHost,
											  stream[st]));

					std::cout << "Third:" << std::endl;
					print_data<<<1, 10, 0, stream[st]>>>(&d_dedispersed[st*N_BEAMS]);
					gpuErrchk(cudaStreamSynchronize(stream[st]));

					std::cout << "Fourth:" << std::endl;
					print_data<<<1, 10, 0, stream[st]>>>(&d_dedispersed[st*N_BEAMS]);

					std::cout << "b test data: " << out_dedispersed[st*N_BEAMS] << std::endl;
					std::cout << "b test data: " << out_dedispersed[st*N_BEAMS+1] << std::endl;
					std::cout << "b test data: " << out_dedispersed[st*N_BEAMS+2] << std::endl;

					for (int ii = 0; ii < N_BEAMS; ii++){
						f << out_dedispersed[st*N_BEAMS + ii];
						// std::cout << out_dedispersed[st*N_BEAMS + ii] << ", ";
						if (ii != N_BEAMS - 1){
							f << ",";
						}
					}

					if (current_gemm != N_DIRS-1){
						f << "],\n[";
					} else {
						f<< "]]"<<std::endl;
					}
					#endif

					// gpuErrchk(cudaStreamAddCallback(stream[st], call_write_to_disk, &f, &file_mutex, current_gemm, BlockSync[st], &out_dedispersed[st*N_BEAMS], 0));

					// gpuErrchk(cudaEventRecord(BlockSync[st], stream[st]));

					// thread[st] = std::thread(call_write_to_disk, std::ref(f), std::ref(file_mutex), current_gemm, BlockSync[st], &out_dedispersed[st*N_BEAMS]);
					// thread[st].detach();
				#endif

				// std::cout << "timeSlice["<< st << "] = " << timeSlice[st] << " and " << current_gemm << std::endl;
				
				if (timeSlice[st] == N_GEMMS_PER_BLOCK-1){
					//This is incremented once each time slice in each block is analyzed
					blocks_analyzed++;
				}
				
				timeSlice[st] += N_STREAMS; // increment so the next time slice is processed next

				if (timeSlice[st] >= N_GEMMS_PER_BLOCK){
					timeSlice[st] -= N_GEMMS_PER_BLOCK; //wrap back to the beginning once each gemm in a block has been processed
				}


				if (current_gemm == N_DIRS-1){
					observation_complete = 1;
					std::cout << "obs Complete" << std::endl;
					break;
				}
			}
		}

		// std::cout << "cs : " << current_stream << std::endl;
	}


	// cuProfilerStop();

	for (int st = 0; st < N_STREAMS; st++){
		gpuErrchk(cudaStreamSynchronize(stream[st]));
	}
	std::cout << "Synchronized" << std::endl;

	#if DEBUG
		f.close();
	#endif

	std::cout << "freeing" << std::endl;

	for (int i = 0; i < N_STREAMS; i++){
		gpuErrchk(cudaStreamDestroy(stream[i]));
		gpuBLASchk(cublasDestroy(handle[i]));
	}

	std::cout << "freeing cuda" << std::endl;

	gpuErrchk(cudaFree(d_A));
	gpuErrchk(cudaFree(d_C));
	gpuErrchk(cudaFree(d_B));
	gpuErrchk(cudaFree(d_data));
	gpuErrchk(cudaFree(d_out));
	gpuErrchk(cudaFree(d_inv_max_value));
	gpuErrchk(cudaFree(d_zero));

	#if DEBUG
		gpuErrchk(cudaFree(d_dedispersed));
		gpuErrchk(cudaFree(d_vec_ones));
		gpuErrchk(cudaFree(d_f_one));
		gpuErrchk(cudaFree(d_f_zero));		
	#endif


	std::cout << "freeing host" << std::endl;

	gpuErrchk(cudaHostUnregister(data));
	gpuErrchk(cudaHostUnregister(beam_out));



	delete[] A;
	delete[] data;
	delete[] pos;
	delete[] dir;
	delete[] beam_out;
	std::cout << "freed all1" << std::endl;


	#if DEBUG
		gpuErrchk(cudaHostUnregister(out_dedispersed));
		std::cout << "freed all2" << std::endl;
		delete[] vec_ones;
		std::cout << "freed all3" << std::endl;
		delete[] out_dedispersed;
	#endif

	std::cout << "freed all4" << std::endl;

	return 0;
}






