#include "beamformer.cuh"


int main(int argc, char *argv[]){
	
	int gpu = 0;
	int observation_complete=0;

	/***************************************************
	DADA VARIABLES
	***************************************************/
	#ifndef DEBUG
		dada_hdu_t* hdu_in = 0;
		multilog_t* log = 0;
		int core = -1;
		key_t in_key = 0x0000dada;
		uint64_t header_size = 0;
	#endif

	/***************************************************
	Antenna Location & Beam Direction Variables
	***************************************************/

	antenna* pos = new antenna[N_ANTENNAS]();		// Locations of antennas
	beam_direction* dir = new beam_direction[N_BEAMS]();		// Direction of bemformed beams

	bool pos_set = false;
	bool dir_set = false;

	/***************************************************
	Parse Command Line Options
	***************************************************/
	int arg = 0;
	std::ifstream input_file;

	#if DEBUG	
		char legal_commandline_options[] = {'f',':','d',':','h'};
	#else
		char legal_commandline_options[] = {'c',':','k',':','g',':','f',':','d',':','h'};
	#endif

	while ((arg=getopt(argc, argv,legal_commandline_options)) != -1) {
		switch (arg) {
			#ifndef DEBUG
			case 'c':
				/* to bind to a cpu core */
				if (optarg){
					core = atoi(optarg);
					break;
				} else {
					printf ("ERROR: -c flag requires argument\n");
					return EXIT_FAILURE;
				}
				
			case 'k':
				/* to set the dada key */
				if (sscanf (optarg, "%x", &in_key) != 1) {
					fprintf (stderr, "beam: could not parse key from %s\n", optarg);
					return EXIT_FAILURE;
				}
				break;
			case 'g':
				/* to set the gpu */
				if (optarg){
					gpu = atoi(optarg);
					break;
				} else {
					printf ("ERROR: -g flag requires argument\n");
					return EXIT_FAILURE;
				}
			#endif

			case 'f':
				/* To setup antenna position locations */
				char* pos_file_name = calloc(256,sizeof(char));
				if (sscanf (optarg, "%s", &pos_file_name) != 1) {
					fprintf (stderr, "beam: could not parse position file from %s\n", optarg);
					return EXIT_FAILURE;
				}
				input_file.open(pos_file_name);
				int nant;
				input_file >> nant;
				if (nant != N_ANTENNAS){
					std::cout << "Number of antennas in file (" << nant << ") does not match N_ANTENNAS ("<< N_ANTENNAS << ")" <<std::cout;
					std::cout << "Excess antennas will be ignored, missing antennas will be set to 0." << std::cout;
				}

				for (int ant = 0; ant < N_ANTENNAS; ant++){
					input_file >> pos[ant].x >> pos[ant].y >> pos[ant].z;
					std::cout << "Read in: (" << pos[ant].x << ", " << pos[ant].y << ", " << pos[ant].z << ")" << std::endl;
				}
				pos_set = true;
				break;
			case 'd':
				/* To setup beamforming directions */
				char* dir_file_name = calloc(256,sizeof(char));
				if (sscanf (optarg, "%s", &dir_file_name) != 1) {
					fprintf (stderr, "beam: could not parse direction file from %s\n", optarg);
					return EXIT_FAILURE;
				}
				input_file.open(dir_file_name);
				int nbeam;
				input_file >> nbeam;
				if (nbeam != N_BEAMS){
					std::cout << "Number of beams in file (" << nbeam << ") does not match N_BEAMS ("<< N_BEAMS << ")" <<std::cout;
					std::cout << "Excess beams will be ignored, missing beams will be set to 0." << std::cout;
				}

				for (int beam_idx = 0; beam_idx < N_BEAMS; beam_idx++){
					input_file >> dir[beam_idx].theta >> dir[beam_idx].phi;
					std::cout << "Read in: (" << dir[beam_idx].theta << ", " << dir[beam_idx].phi << ")" << std::endl;
				}
				dir_set = true;
				break;
			case 'h':
				usage();
				return EXIT_SUCCESS;
		}
	}

	if (!pos_set){
		/* Populate location/direction Matricies */
		for (int i = 0; i < N_ANTENNAS; i++){
			pos[i].x = i*500.0/(N_ANTENNAS-1) - 250.0;
		}
	}

	if (!dir_set){
		/* Directions for Beamforming */
		for (int i = 0; i < N_BEAMS; i++){
			dir[i].theta = i*DEG2RAD(2*HALF_FOV)/(N_BEAMS-1) - DEG2RAD(HALF_FOV);
		}
	}


	/***********************************
	 *			GPU Variables		   *
	 ***********************************/

	std::cout << "Executing beamformer.cu" << std::endl;
	print_all_defines();

	char prefered_dev_name[] = "GeForce GTX 1080";
	int devicesCount;
	cudaGetDeviceCount(&devicesCount);
	for(int deviceIndex = 0; deviceIndex < devicesCount; ++deviceIndex)
	{
	    cudaDeviceProp deviceProperties;
	    cudaGetDeviceProperties(&deviceProperties, deviceIndex);
	    if (prefered_dev_name[14] == deviceProperties.name[14]){
		    std::cout <<  "Selected: " << deviceProperties.name << std::endl;
		    std::cout << "letter: " << prefered_dev_name[14] << std::endl;
		    gpuErrchk(cudaSetDevice(deviceIndex));
		}
	}


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
	#if DEBUG
		char *data = new char[N_BYTES_PRE_EXPANSION_PER_GEMM*N_DIRS](); // storage for test signals
		gpuErrchk(cudaHostRegister(data, N_BYTES_PRE_EXPANSION_PER_GEMM*N_DIRS*sizeof(char), cudaHostRegisterPortable)); //need pinned memory
	#endif

	CxInt8_t *A = new CxInt8_t[A_cols*A_rows*N_FREQUENCIES];
	float *beam_out = new float[N_F_PER_DETECT*N_STREAMS]();
	gpuErrchk(cudaHostRegister(beam_out, N_FREQUENCIES*N_BEAMS*N_OUTPUTS_PER_GEMM*N_STREAMS*sizeof(float), cudaHostRegisterPortable)); //need pinned memory



	#if DEBUG
		/* File for data output */
		std::ofstream f;
		f.open("bin/data.py"); // written such that it can be imported into any python file
		f << "A = [[";


		/* Vectors of all ones for de-dispersion */
		float *d_dedispersed;	// Data after being de-dispersed
		float *out_dedispersed = new float[N_BEAMS*N_DIRS]();
		gpuErrchk(cudaHostRegister(out_dedispersed, N_BEAMS*N_DIRS*sizeof(float), cudaHostRegisterPortable));

		float *d_vec_ones;		
		float *vec_ones = new float[N_FREQUENCIES]; 
		for (int i = 0; i < N_FREQUENCIES; i++){
			vec_ones[i] = 1.0;
		}
	#endif


	/***********************************
	 *		Fourier Coefficients 	   *
	 ***********************************/

	for (int i = 0; i < N_FREQUENCIES; i++){
		float freq = END_F - (ZERO_PT + gpu*TOT_CHANNELS/(N_GPUS-1) + i)*bw_per_channel;
		float wavelength = C_SPEED/(1E9*freq);
		for (int j = 0; j < N_ANTENNAS; j++){
			for (int k = 0; k < N_BEAMS; k++){
				A[i*A_stride + j*N_BEAMS + k].x = round(MAX_VAL*cos(-2*PI*pos[j].x*sin(dir[k].theta)/wavelength));
				A[i*A_stride + j*N_BEAMS + k].y = round(MAX_VAL*sin(-2*PI*pos[j].x*sin(dir[k].theta)/wavelength));
			}
		}
	}


	/***********************************
	 *			Memory Allocation 	   *
	 ***********************************/
	gpuErrchk(cudaMalloc(&d_A, 	A_rows*A_cols*N_FREQUENCIES*sizeof(CxInt8_t)));
	gpuErrchk(cudaMalloc(&d_B, 	N_CX_IN_PER_GEMM*N_STREAMS*sizeof(CxInt8_t)));
	gpuErrchk(cudaMalloc(&d_C, 	N_CX_OUT_PER_GEMM*N_STREAMS*sizeof(cuComplex)));
	gpuErrchk(cudaMalloc(&d_data, N_BYTES_PER_BLOCK*N_BLOCKS_on_GPU)); 							// array for raw data
	gpuErrchk(cudaMalloc(&d_out, N_F_PER_DETECT*N_STREAMS * sizeof(float)));			// array for detected, averaged data

	/* Cublas Constant Memory */
	gpuErrchk(cudaMalloc(&d_inv_max_value, sizeof(cuComplex)));
	gpuErrchk(cudaMalloc(&d_zero, sizeof(cuComplex)));
	


	#if DEBUG
		gpuErrchk(cudaMalloc(&d_vec_ones, N_FREQUENCIES*sizeof(float)));
		gpuErrchk(cudaMalloc(&d_f_one, sizeof(float)));
		gpuErrchk(cudaMalloc(&d_f_zero, sizeof(float)));
		gpuErrchk(cudaMalloc(&d_dedispersed, N_BEAMS*N_STREAMS*sizeof(float)));						// array for frequency averaged data
		
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

	int priority_high, priority_low;
	cudaDeviceGetStreamPriorityRange(&priority_low, &priority_high);

	cudaStream_t HtoDstream;
	cudaStream_t stream[N_STREAMS];

	cublasHandle_t handle[N_STREAMS];
	// std::thread thread[N_STREAMS];
	int timeSlice[N_STREAMS];
	cudaEvent_t BlockTransferredSync[5*N_BLOCKS_on_GPU];
	cudaEvent_t BlockAnalyzedSync[5*N_BLOCKS_on_GPU];

	// gpuErrchk(cudaStreamCreateWithPriority(&HtoDstream, cudaStreamNonBlocking, priority_high));
	gpuErrchk(cudaStreamCreate(&HtoDstream));

	for (int i = 0; i < N_STREAMS; i++){
		// gpuErrchk(cudaStreamCreateWithPriority(&stream[i], cudaStreamNonBlocking, priority_high));
		gpuErrchk(cudaStreamCreate(&stream[i]));
		gpuBLASchk(cublasCreate(&handle[i]));
		gpuBLASchk(cublasSetStream(handle[i], stream[i]));
		gpuBLASchk(cublasSetPointerMode(handle[i], CUBLAS_POINTER_MODE_DEVICE));
		// cublasMath_t mode; 
		// gpuBLASchk(cublasGetMathMode(handle[i], &mode));
		// std::cout << "Mode[" << i << "] == " << mode << std::endl;
		gpuBLASchk(cublasSetMathMode(handle[i], CUBLAS_TENSOR_OP_MATH ));
		// gpuBLASchk(cublasGetMathMode(handle[i], &mode));
		// std::cout << "Mode[" << i << "] == " << mode << std::endl;
		timeSlice[i] = i;
	}
	

	for (int i = 0; i < 5*N_BLOCKS_on_GPU; i++){
		gpuErrchk(cudaEventCreateWithFlags(&BlockTransferredSync[i], cudaEventDisableTiming));
		gpuErrchk(cudaEventCreateWithFlags(&BlockAnalyzedSync[i], cudaEventDisableTiming));
	}

	/***********************************
	 *			TEST SIGNAL			   *
	 ***********************************/

	#if DEBUG
		#if GENERATE_TEST_DATA
			float test_direction;
			char high, low;
			for (int iii = 0; iii < N_DIRS; iii++){
				test_direction = DEG2RAD(-HALF_FOV) + iii*DEG2RAD(2*HALF_FOV)/(N_DIRS-1);
				for (int i = 0; i < N_FREQUENCIES; i++){
					float freq = END_F - (ZERO_PT + gpu*TOT_CHANNELS/(N_GPUS-1) + i)*BW_PER_CHANNEL;
					// std::cout << "freq: " << freq << std::endl;
					float wavelength = C_SPEED/(1E9*freq);
					for (int j = 0; j < N_TIMESTEPS_PER_GEMM; j++){
						for (int k = 0; k < N_ANTENNAS; k++){

							high = ((char) round(SIG_MAX_VAL*cos(2*PI*pos[k].x*sin(test_direction)/wavelength))); //real
							low  = ((char) round(SIG_MAX_VAL*sin(2*PI*pos[k].x*sin(test_direction)/wavelength))); //imag

							data[iii*N_BYTES_PRE_EXPANSION_PER_GEMM + i*B_stride + j*N_ANTENNAS + k] = (high << 4) | (0x0F & low);
						}
					}
				}
			}
		#else
			/* Generates Bogus data, typically 0x70 */
			memset(data, BOGUS_DATA, N_BYTES_PRE_EXPANSION_PER_GEMM*N_DIRS*sizeof(char));
			std::cout << "BOGUS DATA " << std::endl;
		#endif
	#endif 

	// std::cout << "done writing data" << std::endl;

	// int observation_complete = 0;
	uint64_t blocks_analyzed = 0;
	uint64_t blocks_transferred = 0;
	uint64_t blocks_analysis_queue = 0;
	uint64_t blocks_transfer_queue = 0;

	#if DEBUG
		int current_gemm = 0;
	#endif



	/***************************************************
	Initialize hdu (FOR DADA)
	***************************************************/

	#ifndef DEBUG
		// DADA stuff
		log = multilog_open ("real", 0);
		multilog_add (log, stderr);
		multilog (log, LOG_INFO, "creating hdu\n");

		// create dada hdu
		hdu_in	= dada_hdu_create (log);
		// set the input hdu key
		dada_hdu_set_key (hdu_in, in_key);

		// connect to dada buffer
		if (dada_hdu_connect (hdu_in) < 0) {
			printf ("could not connect to dada buffer\n");
			return EXIT_FAILURE;
		}

		// lock read on buffer
		if (dada_hdu_lock_read (hdu_in) < 0) {
			printf ("could not lock to dada buffer\n");
			return EXIT_FAILURE;
		}

		// Bind to cpu core
		if (core >= 0)
		{
			printf("binding to core %d\n", core);
			if (dada_bind_thread_to_core(core) < 0)
			printf("failed to bind to core %d\n", core);
		}

		#if VERBOSE
			multilog (log, LOG_INFO, "Done setting up buffer\n");
		#endif
	#endif

	/***************************************************
	Deal with Headers (FOR DADA)
	***************************************************/
	#ifndef DEBUG
		// read the headers from the input HDU and mark as cleared
		// will block until header is present in dada ring buffer
		char * header_in = ipcbuf_get_next_read (hdu_in->header_block, &header_size);
		if (!header_in)
		{
			multilog(log ,LOG_ERR, "main: could not read next header\n");
			dsaX_dbgpu_cleanup (hdu_in, log);
			return EXIT_FAILURE;
		}

		if (ipcbuf_mark_cleared (hdu_in->header_block) < 0)
		{
			multilog (log, LOG_ERR, "could not mark header block cleared\n");
			dsaX_dbgpu_cleanup (hdu_in, log);
			return EXIT_FAILURE;
		}

		// size of block in dada buffer
		uint64_t block_size = ipcbuf_get_bufsz ((ipcbuf_t *) hdu_in->data_block);
		uint64_t bytes_read = 0, block_id;
		char *block;

		#if VERBOSE
			multilog (log, LOG_INFO, "Done setting up header \n");
		#endif
		
		std::cout << "block size is: " << block_size << std::endl;
	#endif



int transfer_separation = 2;
int total_separation = 4;

/*********************************************************************************
						START OBSERVATION LOOP
*********************************************************************************/
	while (!observation_complete){
		
		#if VERBOSE
			/* Header to be printed during every loop */
			std::cout << "##########################################" << std::endl;
			std::cout << "A: " << blocks_analyzed <<  ", AQ: " << blocks_analysis_queue << ", T: " << blocks_transferred << ", TQ: " << blocks_transfer_queue << std::endl;
		#endif 


		/**************************************************
						Copy Data to GPU
		**************************************************/

		/* Data is copied iff the analysis steps and transfer rates are keeping up */
		if ((blocks_transfer_queue - blocks_analyzed < total_separation) && (blocks_transfer_queue - blocks_transferred < transfer_separation)){

			#if DEBUG
				/***********************************
				IF debugging, copy from "data" array
				***********************************/
				if (blocks_transfer_queue < N_DIRS/N_GEMMS_PER_BLOCK){
					/* Only initiate transfers if fewer than N_DIRS directions have been analyzed */

					#if VERBOSE 
						std::cout << "VERBOSE: Async copy" << std::endl;
					#endif

					/* Copy Block */
					gpuErrchk(cudaMemcpyAsync(&d_data[N_BYTES_PER_BLOCK*(blocks_transfer_queue%N_BLOCKS_on_GPU)], 
												&data[N_BYTES_PER_BLOCK*blocks_transfer_queue],
												N_BYTES_PER_BLOCK, 
												cudaMemcpyHostToDevice,
												HtoDstream));

					/* Generate Cuda event which will indicate when the block has been transfered*/
					gpuErrchk(cudaEventRecord(BlockTransferredSync[blocks_transfer_queue%(5*N_BLOCKS_on_GPU)], HtoDstream));
					blocks_transfer_queue++;
				}
			#else
				/***********************************
					Else copy from PSRDADA block
				***********************************/

				block = ipcio_open_block_read(hdu_in->data_block,&bytes_read, &block_id);

				if (bytes_read != N_BYTES_PER_BLOCK){
					std::cout << "ERROR: Async, Bytes Read: " << bytes_read << ", Should also be "<< N_BYTES_PER_BLOCK << std::endl;
				}

				if (bytes_read < block_size){
					/* If there isn't enough data in the block, end the observation */
					observation_complete = 1;
					break;
				}

				/* Copy Block */
				gpuErrchk(cudaMemcpyAsync(&d_data[N_BYTES_PER_BLOCK*(blocks_transfer_queue%N_BLOCKS_on_GPU)], 
											block,
											N_BYTES_PER_BLOCK, 
											cudaMemcpyHostToDevice,
											HtoDstream));

				/* Mark PSRDADA as read */
				ipcio_close_block_read (hdu_in->data_block, bytes_read);

				/* Generate Cuda event which will indicate when the block has been transfered*/
				gpuErrchk(cudaEventRecord(BlockTransferredSync[blocks_transfer_queue%(5*N_BLOCKS_on_GPU)], HtoDstream));
				blocks_transfer_queue++;
			#endif
		}

		/**************************************************
				Check if data has been transfered
		**************************************************/

		/* Iterate through all left-over blocks and see if they've been finished */
		for (uint64_t event = blocks_transferred; event < blocks_transfer_queue; event ++){
			if(cudaEventQuery(BlockTransferredSync[event%(5*N_BLOCKS_on_GPU)]) == cudaSuccess){
			
				#if VERBOSE
					std::cout << "Block " << event << " transfered to GPU" << std::endl;
				#endif

				blocks_transferred ++;

				/* Destroy and Recreate Flags */
				gpuErrchk(cudaEventDestroy(BlockTransferredSync[event%(5*N_BLOCKS_on_GPU)]));
				gpuErrchk(cudaEventCreateWithFlags(&BlockTransferredSync[event%(5*N_BLOCKS_on_GPU)], cudaEventDisableTiming));
			} else {
				break; // dont need to check later blocks if current block has not finished
			}
		}

		/**************************************************
					Initiate Beamforming
		**************************************************/
		if (blocks_analysis_queue < blocks_transferred){

			for (int part = 0; part < N_GEMMS_PER_BLOCK/N_STREAMS; part++){

				#if VERBOSE
					std::cout << "Queueing Beamforming. Analyzed = " << blocks_analyzed << " Transferred = " << blocks_transferred << " Start Dir = " << blocks_analysis_queue*N_GEMMS_PER_BLOCK + timeSlice[0] << std::endl; 
				#endif

				for (int st = 0; st < N_STREAMS; st++){

					/* Expand input from 4-bit integers to 8-bit integers */
					expand_input<<<10000, 32, 0, stream[st]>>>(&d_data[N_BYTES_PRE_EXPANSION_PER_GEMM*(N_GEMMS_PER_BLOCK*(blocks_analysis_queue%N_BLOCKS_on_GPU) + timeSlice[st])],
														      (char *) &d_B[N_CX_IN_PER_GEMM*st], 
														      B_stride*N_FREQUENCIES);


					/* Execute Beamforming Matrix Multiplication */
					gpuBLASchk(cublasGemmStridedBatchedEx(handle[st], CUBLAS_OP_N, CUBLAS_OP_N,
												A_rows, B_cols, A_cols,
												d_inv_max_value,
												d_A, CUDA_C_8I, A_rows, A_stride,
												&d_B[N_CX_IN_PER_GEMM*st], CUDA_C_8I, B_rows, B_stride,
												d_zero,
												&d_C[N_CX_OUT_PER_GEMM*st], CUDA_C_32F, C_rows, C_stride,
												N_FREQUENCIES, CUDA_C_32F, CUBLAS_GEMM_DEFAULT_TENSOR_OP));


					/* Square results and average */
					detect_sum<<<detect_dimGrid, detect_dimBlock, 0, stream[st]>>>(&d_C[N_CX_OUT_PER_GEMM*st], N_INPUTS_PER_OUTPUT, &d_out[st*N_F_PER_DETECT]);


					/* Copy Data back to CPU RAM */
					gpuErrchk(cudaMemcpyAsync(&beam_out[st*N_F_PER_DETECT], 
											  &d_out[st*N_F_PER_DETECT], N_OUTPUTS_PER_GEMM*N_FREQUENCIES*N_BEAMS*sizeof(float), 
											  cudaMemcpyDeviceToHost,
											  stream[st]));

					#if DEBUG
						current_gemm = blocks_analysis_queue*N_GEMMS_PER_BLOCK + timeSlice[st];
						std::cout << "Current GEMM: " << current_gemm << std::endl;

						/* Sum over all 256 frequencies with a matrix-vector multiplication. */
						gpuBLASchk(cublasSgemv(handle[st], CUBLAS_OP_N,
									N_BEAMS, N_FREQUENCIES,
									d_f_one,
									&d_out[st*N_F_PER_DETECT], N_BEAMS,
									d_vec_ones, 1,
									d_f_zero,
									&d_dedispersed[st*N_BEAMS], 1));

						/* Copy Frequency-averaged data back to CPU */
						gpuErrchk(cudaMemcpyAsync(&out_dedispersed[current_gemm*N_BEAMS], 
												  &d_dedispersed[st*N_BEAMS], N_BEAMS*sizeof(float), 
												  cudaMemcpyDeviceToHost,
												  stream[st]));
					#endif

					
					timeSlice[st] += N_STREAMS; // increment so the next time slice is processed next

					if (timeSlice[st] >= N_GEMMS_PER_BLOCK){
						timeSlice[st] -= N_GEMMS_PER_BLOCK; //wrap back to the beginning once each gemm in a block has been processed
					}

				}
			}
			gpuErrchk(cudaEventRecord(BlockAnalyzedSync[blocks_analysis_queue%(5*N_BLOCKS_on_GPU)], stream[N_STREAMS-1]));
			blocks_analysis_queue ++;
		}


		/**************************************************
				Check if beamforming has completed
		**************************************************/
		for (uint64_t event = blocks_analyzed; event < blocks_analysis_queue; event ++){
			if(cudaEventQuery(BlockAnalyzedSync[event%(5*N_BLOCKS_on_GPU)]) == cudaSuccess){
				//This is incremented once each time slice in each block is analyzed (or more accurately, scheduled)
				blocks_analyzed++;
				#if VERBOSE
					std::cout << "Block " << event << " Analyzed" << std::endl;
				#endif
				gpuErrchk(cudaEventDestroy(BlockAnalyzedSync[event%(5*N_BLOCKS_on_GPU)]));
				gpuErrchk(cudaEventCreateWithFlags(&BlockAnalyzedSync[event%(5*N_BLOCKS_on_GPU)], cudaEventDisableTiming));
				#if DEBUG
					if ((current_gemm == N_DIRS-1) && (blocks_analyzed == blocks_transfer_queue)){
						observation_complete = 1;
						std::cout << "obs Complete" << std::endl;
						break;
					}
				#endif
				
			} else {
				break; // If previous analyzed blocks have not been finished, there's no reason to check the next blocks
			}
		}
	} // end while (!observation_complete)


	for (int st = 0; st < N_STREAMS; st++){
		gpuErrchk(cudaStreamSynchronize(stream[st]));
	}
	std::cout << "Synchronized" << std::endl;

	for (int event = 0; event < 5*N_BLOCKS_on_GPU; event++){
		gpuErrchk(cudaEventDestroy(BlockAnalyzedSync[event]));
		gpuErrchk(cudaEventDestroy(BlockTransferredSync[event]));
	}


	#if DEBUG
		/* Export debug data to a python file. */
		for (int jj = 0; jj < N_DIRS; jj++){
			for (int ii = 0; ii < N_BEAMS; ii++){
				f << out_dedispersed[jj*N_BEAMS + ii];
				// std::cout << out_dedispersed[jj*N_BEAMS + ii] << ", ";
				if (ii != N_BEAMS - 1){
					f << ",";
				}
			}

			if (jj != N_DIRS-1){
				f << "],\n[";
			} else {
				f<< "]]"<<std::endl;
			}
		}

		f.close();
	#endif

	std::cout << "Freeing Structures" << std::endl;

	for (int i = 0; i < N_STREAMS; i++){
		gpuErrchk(cudaStreamDestroy(stream[i]));
		gpuBLASchk(cublasDestroy(handle[i]));
	}

	std::cout << "Freed cuda streams and handles" << std::endl;

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


	std::cout << "Freed GPU memory" << std::endl;

	// gpuErrchk(cudaHostUnregister(data));
	gpuErrchk(cudaHostUnregister(beam_out));

	delete[] A;
	delete[] pos;
	delete[] dir;
	delete[] beam_out;

	#if DEBUG
		delete[] data;
		delete[] vec_ones;
		gpuErrchk(cudaHostUnregister(out_dedispersed));
		delete[] out_dedispersed;
	#endif

	std::cout << "Freed CPU memory" << std::endl;

	return 0;
}







