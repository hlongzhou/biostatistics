#include <stdio.h>
#include <stdlib.h>
#include <cutil.h>
#include <cmeansMultiGPU.h>
#include <cmeansMultiGPUcu.h>
#include <float.h>

__global__ void UpdateClusterCentersGPU(const float* oldClusters, const float* events, float* newClusters, float* distanceMatrix, float* denominator_result, int start_event, int finish_event){

	float membershipValue;//, denominator;
	
	__shared__ float numerators[NUM_DIMENSIONS*NUM_THREADS];

    // Sum of the memberships computed by each thread
    // The sum of all of these denominators together is effectively the size of the cluster
	__shared__ float denominators[NUM_THREADS];
		
    int tid = threadIdx.x;

    // initialize numerators and denominators to 0
    denominators[tid] = 0;
    for(int j = tid; j < NUM_DIMENSIONS*NUM_THREADS; j+=NUM_THREADS){
        numerators[j] = 0;
    }

    __syncthreads();
     
    // Compute new membership value for each event
    // Add its contribution to the numerator and denominator for that thread
    for(int j = start_event+tid; j < finish_event; j+=NUM_THREADS){
          
        membershipValue = MembershipValueGPU(blockIdx.x, j, distanceMatrix);
        #if FUZZINESS == 2 
            // This is much faster than the pow function
            membershipValue = membershipValue*membershipValue;
        #else
            membershipValue = pow(membershipValue,FUZZINESS);
        #endif

        // Note: this access pattern for numerators and events is not coalesced (its accessing columns)
        #pragma unroll 1 // Prevent compiler from unrolling this loop too much, eats up too many registers
        for(int k = 0; k < NUM_DIMENSIONS; k++){
            numerators[tid*NUM_DIMENSIONS + k] += events[k*NUM_EVENTS + j]*membershipValue;
            //numerators[tid*NUM_DIMENSIONS + k] += events[j*NUM_DIMENSIONS + k]*membershipValue;
        }
        denominators[tid] += membershipValue;
    } 

    __syncthreads();
	  
    // Sum up the numerators, one for each dimension	
    // (reducing all rows of numerators into the first row)
    // One thread per dimension
	if(tid < NUM_DIMENSIONS){
        for(int j = 1; j < NUM_THREADS; j++){
            numerators[tid] += numerators[j*NUM_DIMENSIONS+tid];
        }  
        //numerators[tid] = numerators[tid] / (float)NUM_THREADS;
	}

    // Sum up the denominator, one for this block
    if(tid == 0){
      for(int j = 1; j < NUM_THREADS; j++){
        denominators[0] += denominators[j];
      }
      //denominators[0] = denominators[0]/NUM_THREADS;
      denominator_result[blockIdx.x] = denominators[0];
    }
    __syncthreads();

	// Set the new center for this block	
    if(tid < NUM_DIMENSIONS) {
        //newClusters[blockIdx.x*NUM_DIMENSIONS + tid] = numerators[tid]/denominators[0];
        
        // The denominator will get handled by the host
        newClusters[blockIdx.x*NUM_DIMENSIONS + tid] = numerators[tid];
    }
}

__global__ void UpdateClusterCentersGPU2(const float* oldClusters, const float* events, float* newClusters, float* memberships, float* denoms, int start, int finish) {

    float membershipValue;//, denominator;

    int d = blockIdx.y;
    int event_matrix_offset = NUM_EVENTS*d;
    int membership_matrix_offset = NUM_EVENTS*blockIdx.x;

    __shared__ float numerators[NUM_THREADS_UPDATE];

    // Sum of the memberships computed by each thread
    // The sum of all of these denominators together is effectively the size of the cluster
    __shared__ float denominators[NUM_THREADS_UPDATE];
        
    int tid = threadIdx.x;

    // initialize numerators and denominators to 0
    denominators[tid] = 0;
    numerators[tid] = 0;

    __syncthreads();
     
    // Compute new membership value for each event
    // Add its contribution to the numerator and denominator for that thread
    for(int j = start+tid; j < finish; j+=NUM_THREADS_UPDATE){
        membershipValue = memberships[blockIdx.x*NUM_EVENTS + j];
        numerators[tid] += events[event_matrix_offset + j]*membershipValue;
        denominators[tid] += membershipValue;
    } 

    __syncthreads();

    if(tid == 0){
        // Sum up the numerator/denominator, one for this block
        for(int j = 1; j < NUM_THREADS_UPDATE; j++){
            numerators[0] += numerators[j];
        }  
        if(d == 0) {
            for(int j = 1; j < NUM_THREADS_UPDATE; j++){
                denominators[0] += denominators[j];
            }
            denoms[blockIdx.x] = denominators[0];
        }
        // Set the new center for this block    
        //newClusters[blockIdx.x*NUM_DIMENSIONS + d] = numerators[0]/denominators[0];
        newClusters[blockIdx.x*NUM_DIMENSIONS + d] = numerators[0];
    }
}

// TODO: could be reorganized with more blocks, resources are underutilized with number of clusters is small
__global__ void ComputeDistanceMatrix(const float* clusters, const float* events, float* matrix, int start, int stop) {
    
    // copy centers into shared memory	
    __shared__ float center[NUM_DIMENSIONS];
    for(int j = threadIdx.x; j < NUM_DIMENSIONS; j+=NUM_THREADS_DISTANCE){
        center[j] = clusters[blockIdx.x*NUM_DIMENSIONS+j];
    }

    __syncthreads();

    // For each event
    // Note: global memory writes should be coalesced, but the event data access in CalculateDistanceGPU isn't
    for(int i=(start+threadIdx.x); i < stop; i+= NUM_THREADS_DISTANCE) {
        matrix[blockIdx.x*NUM_EVENTS+i] = CalculateDistanceGPU(center,events,blockIdx.x,i);
    }
}

__global__ void ComputeMembershipMatrix(float* distances, float* memberships, int start, int finish) {
    float membershipValue;

    // For each event
    for(int i=start+threadIdx.x; i < finish; i+= NUM_THREADS_MEMBERSHIP) {
        membershipValue = MembershipValueGPU(blockIdx.x, i, distances);
        #if FUZZINESS == 2 
            // This is much faster than the pow function
            membershipValue = membershipValue*membershipValue;
        #else
            membershipValue = pow(membershipValue,FUZZINESS);
        #endif
        memberships[blockIdx.x*NUM_EVENTS+i] = membershipValue;
    }

}

__device__ float MembershipValueGPU(int clusterIndex, int eventIndex, const float* distanceMatrix){
	float myClustDist = 0;
    // Compute the distance from this event to the given cluster
    myClustDist = distanceMatrix[clusterIndex*NUM_EVENTS+eventIndex];
	
	float sum =0;
	float otherClustDist;
    // Compute the distance to all other clusters
    // Note: This is kind of inefficient, because the distance to every other cluster
    // is being re-computed by every other block
    // If each block handled a certain set of events rather than a cluster
    // we might be able to avoid this.
	for(int j = 0; j< NUM_CLUSTERS; j++){
        otherClustDist = distanceMatrix[j*NUM_EVENTS+eventIndex];

		if(otherClustDist < 1e-10)
			return 0.0;
		sum += pow((myClustDist/otherClustDist),(2/(FUZZINESS-1)));
		
	}
	return 1/sum;
}

__device__ float CalculateDistanceGPU(const float* clusters, const float* events, int clusterIndex, int eventIndex){

	float sum = 0;
	float tmp;
#if DISTANCE_MEASURE == 0
    #pragma unroll 1 // Prevent compiler from unrolling this loop too much, eats up too many registers
    for(int i = 0; i < NUM_DIMENSIONS; i++){
        tmp = events[i*NUM_EVENTS+eventIndex] - clusters[i];
        //tmp = events[i*NUM_EVENTS+eventIndex] - clusters[clusterIndex*NUM_DIMENSIONS +i];
        //tmp = events[eventIndex*NUM_DIMENSIONS + i] - clusters[clusterIndex*NUM_DIMENSIONS + i];
        sum += tmp*tmp;
    }
    sum = sqrt(sum);
#endif
#if DISTANCE_MEASURE == 1
    #pragma unroll 1 // Prevent compiler from unrolling this loop too much, eats up too many registers
    for(int i = 0; i < NUM_DIMENSIONS; i++){
        tmp = events[i*NUM_EVENTS+eventIndex] - clusters[i];
        //tmp = events[i*NUM_EVENTS+eventIndex] - clusters[clusterIndex*NUM_DIMENSIONS +i];
        //tmp = events[eventIndex*NUM_DIMENSIONS + i] - clusters[clusterIndex*NUM_DIMENSIONS + i];
        sum += abs(tmp);
    }
#endif
#if DISTANCE_MEASURE == 2 
    #pragma unroll 1 // Prevent compiler from unrolling this loop too much, eats up too many registers
    for(int i = 0; i < NUM_DIMENSIONS; i++){
        tmp = abs(events[i*NUM_EVENTS + eventIndex] - clusters[i]);
        //tmp = abs(events[i*NUM_EVENTS + eventIndex] - clusters[clusterIndex*NUM_DIMENSIONS + i]);
        //tmp = abs(events[eventIndex*NUM_DIMENSIONS + i] - clusters[clusterIndex*NUM_DIMENSIONS + i]);
        if(tmp > sum)
            sum = tmp;
    }
#endif

	return sum;
}


__device__ float CalculateQII(const float* events, float* distanceMatrix, int cluster_index_I, float* EI, float* numMem){
	
	EI[threadIdx.x] = 0;
	numMem[threadIdx.x] = 0;
	
	for(int i = threadIdx.x; i < NUM_EVENTS; i+=Q_THREADS){
        float distance = distanceMatrix[cluster_index_I*NUM_EVENTS+i];
		float memVal = MembershipValueDist(distanceMatrix, cluster_index_I, i, distance);
		
		if(memVal > MEMBER_THRESH){
			EI[threadIdx.x] += pow(memVal, 2) * pow(distance, 2);
			numMem[threadIdx.x]++;
		}
	}
	
	__syncthreads();
	
	if(threadIdx.x == 0){
		for(int i = 1; i < Q_THREADS; i++){
			EI[0] += EI[i];
			numMem[0] += numMem[i];
		}
	}
	__syncthreads();

	return ((((float)K1) * numMem[0]) - (((float)K2) * EI[0]) - (((float)K3) * NUM_DIMENSIONS));

}


__device__ float CalculateQIJ(const float* events, float* distanceMatrix, int cluster_index_I, int cluster_index_J, float * EI, float * EJ, float *numMem){
	
	
	EI[threadIdx.x] = 0;
	EJ[threadIdx.x] = 0;
	numMem[threadIdx.x] = 0;
	
	for(int i = threadIdx.x; i < NUM_EVENTS; i+=Q_THREADS){
        float distance = distanceMatrix[cluster_index_I*NUM_EVENTS+i];
        float memValI = MembershipValueDist(distanceMatrix, cluster_index_I, i, distance);
    
        if(memValI > MEMBER_THRESH){
            EI[threadIdx.x] += pow(memValI, 2) * pow(distance, 2);
            
        }
        
        distance = distanceMatrix[cluster_index_J*NUM_EVENTS+i];
        float memValJ = MembershipValueDist(distanceMatrix, cluster_index_J, i, distance);
        if(memValJ > MEMBER_THRESH){
            EJ[threadIdx.x] += pow(memValJ, 2) * pow(distance, 2);
        }
        if(memValI > MEMBER_THRESH && memValJ > MEMBER_THRESH){
            numMem[threadIdx.x]++;
        }
	}
	__syncthreads();

	if(threadIdx.x == 0){
		for(int i = 1; i < Q_THREADS; i++){
			EI[0] += EI[i];
			EJ[0] += EJ[i];
			numMem[0] += numMem[i];
		}
	}

	__syncthreads();
	float EB = (EI[0] > EJ[0]) ? EI[0] : EJ[0];
	return ((-1*((float)K1)*numMem[0]) + ((float)K2)*EB);

}

__global__ void CalculateQMatrixGPUUpgrade(const float* events, const float* clusters, float* matrix, float* distanceMatrix, int start_row){

	__shared__ float EI[Q_THREADS];
	__shared__ float EJ[Q_THREADS];
	__shared__ float numMem[Q_THREADS];

    int row = blockIdx.x + start_row;
    int col = blockIdx.y;

	if(row == col){
		matrix[row*NUM_CLUSTERS + col ] = CalculateQII(events, distanceMatrix, row, EI, numMem);
	}
	else{
		matrix[row*NUM_CLUSTERS + col] = CalculateQIJ(events, distanceMatrix, row, col, EI, EJ, numMem);
	}	
}

__device__ float MembershipValueDist(float* distanceMatrix, int clusterIndex, int eventIndex, float distance){
	float sum =0;
	float otherClustDist;
	for(int j = 0; j< NUM_CLUSTERS; j++){
        otherClustDist = distanceMatrix[j*NUM_EVENTS+eventIndex];
		if(otherClustDist < 1e-10)
			return 0.0;
		sum += pow((float)(distance/otherClustDist),float(2/(FUZZINESS-1)));
	}
	return 1/sum;
}
