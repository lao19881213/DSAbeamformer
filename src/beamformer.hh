/* beamformer.hh 

	Contains all functions and defines UNrelated to CUDA

*/

#include <iostream>
#include <sstream>
#include <iomanip>
#include <string>
#include <cmath>
#include <fstream>
#include <cstdint>
#include <unistd.h> //optarg



/* dada includes */
#ifndef DEBUG
	#include <algorithm>
	#include <stdlib.h>
	#include <math.h>
	#include <string.h>
	#include <netdb.h>
	#include <sys/socket.h>
	#include <sys/types.h>
	#include <netinet/in.h>
	#include <time.h>

	#include "dada_client.h"
	#include "dada_def.h"
	#include "dada_hdu.h"
	#include "dada_cuda.h" //pinning memory
	#include "multilog.h"
	#include "ipcio.h"
	#include "ipcbuf.h"
	#include "dada_affinity.h"
	#include "ascii_header.h"
#endif


/***************************************************
				Configuration 
***************************************************/

#if DEBUG
	#define BOGUS_DATA 0x70
#endif

/***************************************************
			    DSA Constants
***************************************************/

#define N_BEAMS 256
#define N_ANTENNAS 64
#define N_FREQUENCIES 256
#define HALF_FOV 3.5

#define N_POL 2				//Number of polarizations
#define N_CX 2				//Number of real numbers in a complex number, namely 2

#if DEBUG
	/* Number of time samples to average after beamforming */
	#define N_AVERAGING 1
#else
	#define N_AVERAGING 16
#endif

// Data Indexing, Offsets
#define N_GPUS 8
#define TOT_CHANNELS 2048
#define START_F 1.28
#define END_F 1.53
#define ZERO_PT 0
#define BW_PER_CHANNEL ((END_F - START_F)/TOT_CHANNELS)

// Numerical Constants
#define C_SPEED 299792458.0
#define PI 3.14159265358979


// Type Constants
#define N_BITS 8
#define MAX_VAL 127

#define SIG_BITS 4
#define SIG_MAX_VAL 7

// Solving Constants
#define N_STREAMS 8
#define MAX_TRANSFER_SEP 2
#define MAX_TOTAL_SEP 4

#if DEBUG
	// These constants define the number of test sources to use.
	#define CEILING(x,y) (((x) + (y) - 1) / (y))
	#define N_PT_SOURCES  3721			// Number of sources
	#define N_SOURCES_PER_BATCH 1024	// Must be divisible by N_GEMMS_PER_BLOCK
	#define N_SOURCE_BATCHES (CEILING(N_PT_SOURCES, N_SOURCES_PER_BATCH))
#endif

/***************************************************
				DEFINED FUNCTIONS
***************************************************/

/* Macro which converts from degrees to radians */
#define DEG2RAD(x) ((x)*PI/180.0)


/***************************************************
				DATA constants
***************************************************/

/* How many matrix multiplications could be executed based on the amount of data on the GPU*/
#define N_GEMMS_PER_GPU 256

/* How many output tensors are generated by each GEMM. This parameter helps improve throughput*/
#define N_OUTPUTS_PER_GEMM 8

/* Based on the size of a dada blocks: How many matrix-matrix multiplacations are needed */
#define N_GEMMS_PER_BLOCK 64

/* For each output, we need to average over 16 iterations and 2 polarizations*/
#define N_INPUTS_PER_OUTPUT (N_POL*N_AVERAGING)

/* This is the number of columns processed in each matrix multiplication (includes 2 pol)*/
#define N_TIMESTEPS_PER_GEMM (N_OUTPUTS_PER_GEMM*N_INPUTS_PER_OUTPUT)

/* Calculates the number of blocks on the GPU given the number of GEMMMs possible on the GPU
   and the number of gemms contained in each block*/
#define N_BLOCKS_ON_GPU (N_GEMMS_PER_GPU/N_GEMMS_PER_BLOCK)

/* Gives the number of events that are created on the GPU. Events are a way of telling the
   system when certain kernels have executed. Would probably be ok if = 1*N_BLOCKS_ON_GPU */
#define N_EVENTS_ON_GPU (5*N_BLOCKS_ON_GPU)

/* Number of complex numbers of input data are needed for each GEMM */
#define N_CX_IN_PER_GEMM  (N_ANTENNAS*N_FREQUENCIES*N_TIMESTEPS_PER_GEMM)

/* Number of Complex numbers of output data are produced in each GEMM */
#define N_CX_OUT_PER_GEMM (N_BEAMS*N_FREQUENCIES*N_TIMESTEPS_PER_GEMM)

/* The detection step averages over N_INPUTS_PER_OUTPUT (16) numbers */
#define N_F_PER_DETECT (N_CX_OUT_PER_GEMM/N_INPUTS_PER_OUTPUT)

/* Number of Bytes of input data are needed for each GEMM, the real part and imaginary parts
   of each complex number use 1 Byte after expansion */
#define N_BYTES_POST_EXPANSION_PER_GEMM  (N_CX_IN_PER_GEMM*N_CX)

/* Number of Bytes before expansion from 4-bit to 8-bit. Each complex number uses half a Byte */
#define N_BYTES_PRE_EXPANSION_PER_GEMM  (N_CX_IN_PER_GEMM*N_CX/2)

/* Number of Bytes (before expansion) for input array */
#define N_BYTES_PER_BLOCK (N_BYTES_PRE_EXPANSION_PER_GEMM*N_GEMMS_PER_BLOCK)

#if DEBUG
	#define INPUT_DATA_SIZE (N_BYTES_PRE_EXPANSION_PER_GEMM*N_SOURCES_PER_BATCH)
	static_assert(N_SOURCES_PER_BATCH%N_GEMMS_PER_BLOCK == 0, "N_SOURCES_PER_BATCH must be divisible by N_GEMMS_PER_BLOCK");
#endif


static_assert(N_BEAMS%(32/N_BITS) == 0, "N_BEAMS must be divisible by 4");
static_assert(N_ANTENNAS%(32/N_BITS) == 0, "N_ANTENNAS must be divisible by 4");



/***************************************************
				TYPES
***************************************************/

typedef char2 CxInt8_t;
typedef char char4_t[4]; //four chars = 32-bit so global memory bandwidth usage is optimal
typedef char char8_t[8]; //eight chars = 64-bit so global memory bandwidth usage is optimal
typedef CxInt8_t cuChar4_t[4];





class antenna{
/* Class which manages the x, y, and z positions of each antenna */
public:
	float x, y, z;
	antenna(){x = 0; y = 0; z = 0;}
};





class beam_direction{
/* Class which manages the theta and phi directions of each beam */
public:
	float theta, phi;
	beam_direction(){theta = 0; phi = 0;}
	beam_direction(float th, float ph) : theta(th), phi(ph) {}
};






class observation_loop_state{
private:
	uint64_t blocks_analyzed = 0;
	uint64_t blocks_transferred = 0;
	uint64_t blocks_analysis_queue = 0;
	uint64_t blocks_transfer_queue = 0;
	#if DEBUG
	int source_batch_counter = 0;
	#endif

	uint64_t maximum_transfer_seperation;
	uint64_t maximum_total_seperation;

	bool observation_complete = false;
	bool transfers_complete = false;

public:
	observation_loop_state(uint64_t maximum_transfer_seperation, uint64_t maximum_total_seperation);

	void increment_blocks_analyzed(){blocks_analyzed++;};
	void increment_blocks_transferred(){blocks_transferred++;};
	void increment_blocks_analysis_queue(){blocks_analysis_queue++;};
	void increment_blocks_transfer_queue(){blocks_transfer_queue++;};

	// uint64_t get_blocks_analyzed(){return blocks_analyzed;}
	// uint64_t get_blocks_transferred(){return blocks_transferred;}
	// uint64_t get_blocks_analysis_queue(){return blocks_analysis_queue;}
	// uint64_t get_blocks_transfer_queue(){return blocks_transfer_queue;}

	bool check_ready_for_transfer();
	bool check_ready_for_analysis();
	bool check_observations_complete(int current_gemm);
	bool check_transfers_complete();

	friend std::ostream & operator << (std::ostream &out, const observation_loop_state &a);
};

observation_loop_state::observation_loop_state(uint64_t maximum_transfer_seperation, uint64_t maximum_total_seperation){
	this->maximum_transfer_seperation = maximum_transfer_seperation;
	this->maximum_total_seperation = maximum_total_seperation;
}

bool observation_loop_state::check_ready_for_transfer(){
	return ( (blocks_transfer_queue - blocks_analyzed < maximum_total_seperation)
			 && (blocks_transfer_queue - blocks_transferred < maximum_transfer_seperation)
			 && !transfers_complete );
}

bool observation_loop_state::check_ready_for_analysis(){
	return blocks_analysis_queue < blocks_transferred;
}

bool observation_loop_state::check_observations_complete(int current_gemm){
#if DEBUG
	if ((current_gemm >= N_PT_SOURCES-1) && (blocks_analyzed == blocks_transfer_queue) && transfers_complete){
		observation_complete = 1;
		std::cout << "obs Complete" << std::endl;
		return true;
	} else{
		return false;
	}
#else
	if ((blocks_analyzed == blocks_transfer_queue) && transfers_complete){
		observation_complete = 1;
		std::cout << "obs Complete" << std::endl;
		return true;
	} else{
		return false;
	}
#endif
}

bool observation_loop_state::check_transfers_complete(){
	if (blocks_transfer_queue * N_GEMMS_PER_BLOCK >= N_PT_SOURCES){
		/* If the amount of data queued for transfer is greater than the amount needed for analyzing N_PT_SOURCES, stop */
		transfers_complete = 1;
		return true;
	} else {
		return false;
	}
}

std::ostream & operator << (std::ostream &out, const observation_loop_state &a){
	return out << "A: " << a.blocks_analyzed <<  ", AQ: " << a.blocks_analysis_queue << ", T: " << a.blocks_transferred << ", TQ: " << a.blocks_transfer_queue;
}







#ifndef DEBUG
	class dada_handler{
	private:
		multilog_t* log = 0;
		dada_hdu_t* hdu_in = 0;
		uint64_t header_size = 0;
		uint64_t block_size = 0;
		uint64_t bytes_read = 0;
		uint64_t block_id = 0;

		void dsaX_dbgpu_cleanup(void);
		int dada_cuda_dbregister (dada_hdu_t * hdu);
		int dada_cuda_dbunregister (dada_hdu_t * hdu);

	public:
		dada_handler(char * name, int core, key_t in_key);
		~dada_handler();
		void read_headers(void);
		char* read(uint64_t *bytes_read);
		void close(uint64_t bytes_read);
		bool check_transfers_complete();
		uint64_t get_block_size(){return block_size;}
		uint64_t get_bytes_read(){return bytes_read;}
	};

	dada_handler::dada_handler(char * name, int core, key_t in_key){
		log = multilog_open(name, 0);
		multilog_add(log, stderr);
		multilog(log, LOG_INFO, "creating hdu\n");

		hdu_in = dada_hdu_create(log);
		dada_hdu_set_key(hdu_in, in_key);

		if (dada_hdu_connect(hdu_in) < 0){
			printf ("Error: could not connect to dada buffer\n");
			exit(-1); // return EXIT_FAILURE;		
		}

		// lock read on buffer
		if (dada_hdu_lock_read (hdu_in) < 0) {
			printf ("Error: could not lock to dada buffer (try relaxing memlock limits in /etc/security/limits.conf)\n");
			exit(-1); // return EXIT_FAILURE;
		}

		if (dada_cuda_dbregister(hdu_in) < 0){
			printf ("Error: could not pin dada buffer\n");
			exit(-1); 
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
	}

	dada_handler::~dada_handler(){
		dada_cuda_dbunregister(hdu_in);
	}

	void dada_handler::read_headers(){
		char * header_in = ipcbuf_get_next_read (hdu_in->header_block, &(header_size));
		if (!header_in)
		{
			multilog(log ,LOG_ERR, "main: could not read next header\n");
			dsaX_dbgpu_cleanup();
			exit(-1);
		}

		if (ipcbuf_mark_cleared (hdu_in->header_block) < 0)
		{
			multilog (log, LOG_ERR, "could not mark header block cleared\n");
			dsaX_dbgpu_cleanup();
			exit(-1);
		}

		// size of block in dada buffer
		block_size = ipcbuf_get_bufsz ((ipcbuf_t *) hdu_in->data_block);

		#if VERBOSE
			multilog (log, LOG_INFO, "Done setting up header \n");
		#endif
		
		std::cout << "block size is: " << block_size << std::endl;
	}

	char* dada_handler::read(){
		return ipcio_open_block_read(hdu_in->data_block, &bytes_read, &block_id);
	}

	void dada_handler::close(){
		ipcio_close_block_read (hdu_in->data_block, bytes_read);
	}
	
	bool dada_handler::check_transfers_complete(){
		if (bytes_read < block_size){
			/* If there isn't enough data in the block, end the observation */
			transfers_complete = 1;
			#if VERBOSE
				std::cout <<"bytes_read < block_size, ending transfers" << std::endl;
			#endif
			// ipcio_close_block_read (hdu_in->data_block, bytes_read);
			return true;

		} else {
			return false;
		}
	}

	void dada_handler::dsaX_dbgpu_cleanup() {
		/*cleanup as defined by dada example code */
		if (dada_hdu_unlock_read (hdu_in) < 0){
			multilog(log, LOG_ERR, "could not unlock read on hdu_in\n");
		}
		dada_hdu_destroy (hdu_in);
	}

	
	int dada_handler::dada_cuda_dbregister (dada_hdu_t * hdu) {
		/*! register the data_block in the hdu via cudaHostRegister */
		ipcbuf_t * db = (ipcbuf_t *) hdu->data_block;

		// ensure that the data blocks are SHM locked
		if (ipcbuf_lock (db) < 0) {
			perror("dada_dbregister: ipcbuf_lock failed\n");
			return -1;
		}

		// dont register buffers if they reside on the device
		if (ipcbuf_get_device(db) >= 0) {
			return 0;
		}
		size_t bufsz = db->sync->bufsz;
		unsigned int flags = 0;
		cudaError_t rval;
		// lock each data block buffer as cuda memory
		uint64_t ibuf;

		for (ibuf = 0; ibuf < db->sync->nbufs; ibuf++) {
			rval = cudaHostRegister ((void *) db->buffer[ibuf], bufsz, flags);
			if (rval != cudaSuccess) {
				perror("dada_dbregister:  cudaHostRegister failed\n");
				return -1;
			}
		}
		return 0;
	}

	int dada_handler::dada_cuda_dbunregister (dada_hdu_t * hdu) {
		/*! unregister the data_block in the hdu via cudaHostUnRegister */
		ipcbuf_t * db = (ipcbuf_t *) hdu->data_block;
		cudaError_t error_id;

		// dont unregister buffers if they reside on the device
		if (ipcbuf_get_device(db) >= 0)
		return 0;

		// lock each data block buffer as cuda memory
		uint64_t ibuf;
		for (ibuf = 0; ibuf < db->sync->nbufs; ibuf++) {
			error_id = cudaHostUnregister ((void *) db->buffer[ibuf]);
			if (error_id != cudaSuccess) {
				fprintf (stderr, "dada_dbunregister: cudaHostUnregister failed: %s\n",
				cudaGetErrorString(error_id));
		    	return -1;
		    }
		}
		return 0;
	}

#endif

/***************************************************
				DADA
***************************************************/


/* Usage as defined by dada example code */
#if DEBUG
void usage(){
	fprintf (stdout,
	   "dsaX_beamformer_DEBUG_MODE [options]\n"
	   " -g gpu                  select a predefined frequency range\n"
	   " -p position_filename    file where the antenna positions are stored\n"
	   " -d direction_filename   file where the beam directions are stored\n"
	   " -s source_filename      file where the source directions are stored\n"
	   " -h                      print usage\n");
}
#else
void usage(){
	fprintf (stdout,
	   "dsaX_beamformer [options]\n"
	   " -c core                 bind process to CPU core\n"
	   " -k key                  [default dada]\n"
	   " -g gpu                  select a predefined frequency range\n"
	   " -p position_filename    file where the antenna positions are stored\n"
	   " -d direction_filename   file where the beam directions are stored\n"
	   " -h                      print usage\n");
}
#endif


/***************************************************
				UTILITY FUNCTIONS
***************************************************/

#if DEBUG
void generate_test_data(char *data, beam_direction sources[], antenna pos[], int gpu, int stride, int source_batch_counter){
	// float test_direction;
	char high, low;
	
	for (long direction = 0; direction < N_SOURCES_PER_BATCH; direction++){
		//test_direction = DEG2RAD(-HALF_FOV) + ((float) direction)*DEG2RAD(2*HALF_FOV)/(N_PT_SOURCES-1);

		for (int i = 0; i < N_FREQUENCIES; i++){
			float freq = END_F - (ZERO_PT + gpu*TOT_CHANNELS/(N_GPUS-1) + i)*BW_PER_CHANNEL;
			// std::cout << "freq: " << freq << std::endl;
			float wavelength = C_SPEED/(1E9*freq);
			for (int j = 0; j < N_TIMESTEPS_PER_GEMM; j++){
				for (int k = 0; k < N_ANTENNAS; k++){
					int source_look_up = direction + source_batch_counter*N_SOURCES_PER_BATCH;

					if (source_look_up < N_PT_SOURCES){
						high = ((char) round(SIG_MAX_VAL*cos(2*PI*(pos[k].x*sin(sources[source_look_up].theta) + pos[k].y*sin(sources[source_look_up].phi) )/wavelength))); //real
						low  = ((char) round(SIG_MAX_VAL*sin(2*PI*(pos[k].x*sin(sources[source_look_up].theta) + pos[k].y*sin(sources[source_look_up].phi) )/wavelength))); //imag

						data[direction*N_BYTES_PRE_EXPANSION_PER_GEMM + i*stride + j*N_ANTENNAS + k] = (high << 4) | (0x0F & low);
					} else {
						data[direction*N_BYTES_PRE_EXPANSION_PER_GEMM + i*stride + j*N_ANTENNAS + k] = 0;
					}
				}
			}
		}
	}
}

#endif

int read_in_beam_directions(char * file_name, int expected_beams, beam_direction* dir, bool * dir_set){
	std::ifstream input_file;

	input_file.open(file_name);
	int nbeam;
	input_file >> nbeam;
	if (nbeam != expected_beams){
		std::cout << "Number of beams in file (" << nbeam << ") does not match expected ("<< expected_beams << ")" <<std::endl;
		std::cout << "Excess beams will be ignored, missing beams will be set to 0." << std::endl;
	}

	for (int beam_idx = 0; beam_idx < expected_beams; beam_idx++){
		input_file >> dir[beam_idx].theta >> dir[beam_idx].phi;
	}
	std::cout << std::endl;

	*dir_set = true;
	return 0;
}


int read_in_position_locations(char * file_name, antenna *pos, bool *pos_set){
	std::ifstream input_file;
	input_file.open(file_name);
	int nant;
	input_file >> nant;
	if (nant != N_ANTENNAS){
		std::cout << "Number of antennas in file (" << nant << ") does not match N_ANTENNAS ("<< N_ANTENNAS << ")" <<std::endl;
		std::cout << "Excess antennas will be ignored, missing antennas will be set to 0." << std::endl;
	}

	for (int ant = 0; ant < N_ANTENNAS; ant++){
		input_file >> pos[ant].x >> pos[ant].y >> pos[ant].z;
	}
	std::cout << std::endl;

	*pos_set = true;
	return 0;
}


void write_array_to_disk_as_python_file(float *data_out, int rows, int cols, char * output_filename){
	/* Export debug data to a python file. */

	std::ofstream f; // File for data output
	f.open(output_filename); // written such that it can be imported into any python file
	f << "A = [[";
	
	for (int jj = 0; jj < rows; jj++){
		for (int ii = 0; ii < cols; ii++){
			f << data_out[jj*cols + ii];
			// std::cout << data_out[jj*cols + ii] << ", ";
			if (ii != cols - 1){
				f << ",";
			}
		}

		if (jj != rows-1){
			f << "],\n[";
		} else {
			f<< "]]"<<std::endl;
		}
	}

	f.close();
}


void print_all_defines(void){
	std::cout << "N_BEAMS: " << N_BEAMS << "\n";
	std::cout << "N_ANTENNAS: " << N_ANTENNAS << "\n";
	std::cout << "N_FREQUENCIES: " << N_FREQUENCIES << "\n";
	std::cout << "N_AVERAGING: " << N_AVERAGING << "\n";
	std::cout << "N_POL: " << N_POL << "\n";
	std::cout << "N_CX: " << N_CX << "\n";
	std::cout << "N_GEMMS_PER_GPU: " << N_GEMMS_PER_GPU << "\n";
	std::cout << "N_OUTPUTS_PER_GEMM: " << N_OUTPUTS_PER_GEMM << "\n";
	std::cout << "N_GEMMS_PER_BLOCK: " << N_GEMMS_PER_BLOCK << "\n";
	std::cout << "N_INPUTS_PER_OUTPUT: " << N_INPUTS_PER_OUTPUT << "\n";
	std::cout << "N_TIMESTEPS_PER_GEMM: " << N_TIMESTEPS_PER_GEMM << "\n";
	std::cout << "N_BLOCKS_ON_GPU: " << N_BLOCKS_ON_GPU << "\n";
	std::cout << "N_CX_IN_PER_GEMM: " << N_CX_IN_PER_GEMM << "\n";
	std::cout << "N_CX_OUT_PER_GEMM: " << N_CX_OUT_PER_GEMM << "\n";
	std::cout << "N_BYTES_POST_EXPANSION_PER_GEMM: " << N_BYTES_POST_EXPANSION_PER_GEMM << "\n";
	std::cout << "N_BYTES_PRE_EXPANSION_PER_GEMM: " << N_BYTES_PRE_EXPANSION_PER_GEMM << "\n";
	std::cout << "N_BYTES_PER_BLOCK: " << N_BYTES_PER_BLOCK << "\n";
	std::cout << "N_GPUS: " << N_GPUS << "\n";
	std::cout << "TOT_CHANNELS: " << TOT_CHANNELS << "\n";
	std::cout << "START_F: " << START_F << "\n";
	std::cout << "END_F: " << END_F << "\n";
	std::cout << "ZERO_PT: " << ZERO_PT << "\n";
	std::cout << "BW_PER_CHANNEL: " << BW_PER_CHANNEL << "\n";
	std::cout << "C_SPEED: " << C_SPEED << "\n";
	std::cout << "PI: " << PI <<"\n";
	std::cout << "N_BITS: " << N_BITS << "\n";
	std::cout << "MAX_VAL: " << MAX_VAL << "\n";
	std::cout << "SIG_BITS: " << SIG_BITS << "\n";
	std::cout << "SIG_MAX_VAL: " << SIG_MAX_VAL << "\n";
	std::cout << "N_STREAMS: " << N_STREAMS << "\n";
	#if DEBUG
		std::cout << "N_PT_SOURCES: " << N_PT_SOURCES << "\n";
		std::cout << "N_SOURCE_BATCHES: "  << N_SOURCE_BATCHES << "\n";
		std::cout << "N_SOURCES_PER_BATCH: "  << N_SOURCES_PER_BATCH << "\n";
	#endif

	std::cout << std::endl;
}










