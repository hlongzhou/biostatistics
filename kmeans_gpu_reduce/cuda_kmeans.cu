#include <stdio.h>
#include <stdlib.h>

#include "kmeans.h"

__host__ __device__ inline static
float euclid_dist_2(int    numCoords,
                    int    numObjs,
                    int    numClusters,
                    float *objects,     // [numCoords][numObjs]
                    float *clusters,    // [numCoords][numClusters]
                    int    objectId,
                    int    clusterId)
{
    int i;
    float ans=0.0;

    for (i = 0; i < numCoords; i++) {
        ans += (objects[numObjs * i + objectId] - clusters[numClusters * i + clusterId]) *
               (objects[numObjs * i + objectId] - clusters[numClusters * i + clusterId]);
    }

    return(ans);
}

__global__ static
void find_nearest_cluster(int numCoords,
                          int numObjs,
                          int numClusters,
                          float *objects,           //  [numCoords][numObjs]
                          float *deviceClusters,    //  [numCoords][numClusters]
                          int *membership,          //  [numObjs]
                          int *intermediates)
{
    extern __shared__ char sharedMemory[];

    unsigned char *membershipChanged = (unsigned char *)sharedMemory;
    float *clusters = (float *)(sharedMemory + blockDim.x);
    membershipChanged[threadIdx.x] = 0;

    for (int i = threadIdx.x; i < numClusters; i += blockDim.x) {
        for (int j = 0; j < numCoords; j++) {
            clusters[numClusters * j + i] = deviceClusters[numClusters * j + i];
        }
    }
    __syncthreads();

    int objectId = blockDim.x * blockIdx.x + threadIdx.x;
    if (objectId < numObjs) {
        int   index, i;
        float dist, min_dist;

        index    = 0;
        min_dist = euclid_dist_2(numCoords, numObjs, numClusters,
                                 objects, clusters, objectId, 0);

        for (i=1; i<numClusters; i++) {
            dist = euclid_dist_2(numCoords, numObjs, numClusters,
                                 objects, clusters, objectId, i);
            if (dist < min_dist) { 
                min_dist = dist;
                index    = i;
            }
        }

        if (membership[objectId] != index) {
            membershipChanged[threadIdx.x] = 1;
        }

        membership[objectId] = index;

        __syncthreads();    //  For membershipChanged[]

        for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
            if (threadIdx.x < s) {
                membershipChanged[threadIdx.x] +=
                    membershipChanged[threadIdx.x + s];
            }
            __syncthreads();
        }

        if (threadIdx.x == 0) {
            intermediates[blockIdx.x] = membershipChanged[0];
        }
    }
}

__global__ static
void compute_delta(int *deviceIntermediates,
                   int numIntermediates,    //  The actual number of intermediates
                   int numIntermediates2)   //  The next power of two
{
    extern __shared__ unsigned int intermediates[];

    intermediates[threadIdx.x] =
        (threadIdx.x < numIntermediates) ? deviceIntermediates[threadIdx.x] : 0;

    __syncthreads();

    for (unsigned int s = numIntermediates2 / 2; s > 0; s >>= 1) {
        if (threadIdx.x < s) {
            intermediates[threadIdx.x] += intermediates[threadIdx.x + s];
        }
        __syncthreads();
    }

    if (threadIdx.x == 0) {
        deviceIntermediates[0] = intermediates[0];
    }
}

float** cuda_kmeans(float **objects,      
                   int     numCoords,    
                   int     numObjs,      
                   int     numClusters,  
                   float   threshold,    
                   int    *membership,   
                   int    *numIterations)
{
    int      i, j, index, loop=0;
    int     *newClusterSize; 
    float    delta;         
    float  **dimObjects;
    float  **clusters;       
    float  **dimClusters;
    float  **newClusters; 

    float *deviceObjects;
    float *deviceClusters;
    int *deviceMembership;
    int *deviceIntermediates;

    malloc2D(dimObjects, numCoords, numObjs, float);
    for (i = 0; i < numCoords; i++) {
        for (j = 0; j < numObjs; j++) {
            dimObjects[i][j] = objects[j][i];
        }
    }

    malloc2D(dimClusters, numCoords, numClusters, float);
    for (i = 0; i < numCoords; i++) {
        for (j = 0; j < numClusters; j++) {
            dimClusters[i][j] = dimObjects[i][j];
        }
    }

    for (i=0; i<numObjs; i++) membership[i] = -1;

    newClusterSize = (int*) calloc(numClusters, sizeof(int));
    assert(newClusterSize != NULL);

    malloc2D(newClusters, numCoords, numClusters, float);
    memset(newClusters[0], 0, numCoords * numClusters * sizeof(float));

    const unsigned int numThreadsPerClusterBlock = 128;
    const unsigned int numClusterBlocks =
        (numObjs + numThreadsPerClusterBlock - 1) / numThreadsPerClusterBlock;
    const unsigned int clusterBlockSharedDataSize =
        numThreadsPerClusterBlock * sizeof(unsigned char) +
        numClusters * numCoords * sizeof(float);

    cudaDeviceProp deviceProp;
    int deviceNum;
    cudaGetDevice(&deviceNum);
    cudaGetDeviceProperties(&deviceProp, deviceNum);

    if (clusterBlockSharedDataSize > deviceProp.sharedMemPerBlock) {
        err("WARNING: Your CUDA hardware has insufficient block shared memory. "
            "You need to recompile with BLOCK_SHARED_MEM_OPTIMIZATION=0. "
            "See the README for details.\n");
    }

    const unsigned int numReductionThreads =
        nextPowerOfTwo(numClusterBlocks);
    const unsigned int reductionBlockSharedDataSize =
        numReductionThreads * sizeof(unsigned int);

    checkCuda(cudaMalloc(&deviceObjects, numObjs*numCoords*sizeof(float)));
    checkCuda(cudaMalloc(&deviceClusters, numClusters*numCoords*sizeof(float)));
    checkCuda(cudaMalloc(&deviceMembership, numObjs*sizeof(int)));
    checkCuda(cudaMalloc(&deviceIntermediates, numReductionThreads*sizeof(unsigned int)));

    checkCuda(cudaMemcpy(deviceObjects, dimObjects[0],
              numObjs*numCoords*sizeof(float), cudaMemcpyHostToDevice));
    checkCuda(cudaMemcpy(deviceMembership, membership,
              numObjs*sizeof(int), cudaMemcpyHostToDevice));

    do {
        checkCuda(cudaMemcpy(deviceClusters, dimClusters[0],
                  numClusters*numCoords*sizeof(float), cudaMemcpyHostToDevice));

        find_nearest_cluster
            <<< numClusterBlocks, numThreadsPerClusterBlock, clusterBlockSharedDataSize >>>
            (numCoords, numObjs, numClusters,
             deviceObjects, deviceClusters, deviceMembership, deviceIntermediates);

        cudaDeviceSynchronize(); checkLastCudaError();

        compute_delta <<< 1, numReductionThreads, reductionBlockSharedDataSize >>>
            (deviceIntermediates, numClusterBlocks, numReductionThreads);

        cudaDeviceSynchronize(); checkLastCudaError();

        int d;
        checkCuda(cudaMemcpy(&d, deviceIntermediates,
                  sizeof(int), cudaMemcpyDeviceToHost));
        delta = (float)d;

        checkCuda(cudaMemcpy(membership, deviceMembership,
                  numObjs*sizeof(int), cudaMemcpyDeviceToHost));

        for (i=0; i<numObjs; i++) {
            /* find the array index of nestest cluster center */
            index = membership[i];

            /* update new cluster centers : sum of objects located within */
            newClusterSize[index]++;
            for (j=0; j<numCoords; j++)
                newClusters[j][index] += objects[i][j];
        }

        for (i=0; i<numClusters; i++) {
            for (j=0; j<numCoords; j++) {
                if (newClusterSize[i] > 0)
                    dimClusters[j][i] = newClusters[j][i] / newClusterSize[i];
                newClusters[j][i] = 0.0;   /* set back to 0 */
            }
            newClusterSize[i] = 0;   /* set back to 0 */
        }

        delta /= numObjs;
    } while (delta > threshold && loop++ < 100);

    *numIterations = loop + 1;

    malloc2D(clusters, numClusters, numCoords, float);
    for (i = 0; i < numClusters; i++) {
        for (j = 0; j < numCoords; j++) {
            clusters[i][j] = dimClusters[j][i];
        }
    }

    checkCuda(cudaFree(deviceObjects));
    checkCuda(cudaFree(deviceClusters));
    checkCuda(cudaFree(deviceMembership));
    checkCuda(cudaFree(deviceIntermediates));

    return clusters;
}

template <typename T, typename Op>
__device__ void reduce(T * const array)
{
		Op op;
		if (threadIdx.x < 128) array[threadIdx.x] = op(array[threadIdx.x], array[threadIdx.x + 128]);
		__syncthreads();
		if (threadIdx.x < 64) array[threadIdx.x] = op(array[threadIdx.x], array[threadIdx.x +  64]);
		__syncthreads();
		if (threadIdx.x < 32)
		{
			array[threadIdx.x] = op(array[threadIdx.x], array[threadIdx.x + 32]);
			array[threadIdx.x] = op(array[threadIdx.x], array[threadIdx.x + 16]);
			array[threadIdx.x] = op(array[threadIdx.x], array[threadIdx.x +  8]);
			array[threadIdx.x] = op(array[threadIdx.x], array[threadIdx.x +  4]);
			array[threadIdx.x] = op(array[threadIdx.x], array[threadIdx.x +  2]);
			array[threadIdx.x] = op(array[threadIdx.x], array[threadIdx.x +  1]);
		}
		__syncthreads();

	template <typename T> struct OpPlus { 
		__device__ __host__ T operator () (const T & lhs, const T & rhs) 
		{ return lhs + rhs; } };
		template <typename T> struct OpMax  { 
			__device__ __host__ T operator () (const T & lhs, const T & rhs) 
			{ return (lhs > rhs) ? lhs:rhs; } };
			template <typename T> struct OpMin  { 
				__device__ __host__ T operator () (const T & lhs, const T & rhs) 
				{ return (lhs < rhs) ? lhs:rhs; } };

	template <typename T> __device__ void reduceAdd(T * const array) { reduce<T, OpPlus<T> >(array); }
	template <typename T> __device__ void reduceMax(T * const array) { reduce<T, OpMax <T> >(array); }
	template <typename T> __device__ void reduceMin(T * const array) { reduce<T, OpMin <T> >(array); }
	template <typename T> __device__ void reduceMean(T * const array) { reduce<T, OpPlus <T> >(array)/(gridDim.x*blockDim.x*blockDim.y); }
}
