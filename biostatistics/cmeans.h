#ifndef _CMEANS_H_
#define _CMEANS_H_

#include <time.h>

// CPU vs GPU
#define CPU_ONLY 0
#define MDL_on_GPU 1

// number of clusters
#define NUM_CLUSTERS 50

// number of dimensions
#define ALL_DIMENSIONS 21 

// number of elements
#define NUM_EVENTS 100000

// Parameters
#define FUZZINESS 2
#define THRESHOLD .0001
#define K1 1.0
#define K2 .01
#define K3 1.5
#define MEMBER_THRESH .05
#define TABU_ITER 100
#define TABU_TENURE 5
#define VOLUME_TYPE 0
#define DISTANCE_MEASURE 0


const float VOLUME_INC_PARAMS[] = {.05,0.1,0.15};

// number of Threads and blocks
#define Q_THREADS 92 // number of threads per block building Q
#define NUM_THREADS 128  // number of threads per block
#define NUM_BLOCKS NUM_CLUSTERS
#define NUM_NUM NUM_THREADS
#define PI (3.1415926)

// use file or not - just for testing
#define FAKE 0
// never not 1, should be removed
#define THREADS_PER_EVENT 1

// function definitions

void kmeans_distance_cpu(const float* allClusters, const float* allEvents, int* cM);
float CalcDistCPU(const float* refVecs, const float* events, int eventIndex, int clusterIndex);
float* generateEvents();
bool UpdateCenters(const float* oldClusters, const float* events, int* cMs, float* newClusters);
int* AllocateCM(int* cMs);
float* AllocateClusters(float* clust);
float* AllocateEvents(float* evs);
void generateInitialClusters(float* clusters, float* events);

float CalculateDistanceCPU(const float* clusters, const float* events, int clusterIndex, int eventIndex);
float MembershipValue(const float* clusters, const float* events, int clusterIndex, int eventIndex);
float MembershipValueDist(const float* clusters, const float* events, int eventIndex, float distance);
float MembershipValueReduced(const float* clusters, const float* events, int clusterIndex, int eventIndex, int);
void UpdateClusterCentersCPU(const float* oldClusters, const float* events, float* newClusters);

float* ParseSampleInput(const char* filename);

int* MDL(float* events, float* clusters, float*, char* inputFile);
int* MDLGPU(float* d_events, float* d_clusters, float*, char* inputFile);

float FindScoreGPU(float* d_matrix, long config);
float* BuildQGPU(float* d_events, float* d_clusters, float*);
long TabuSearchGPU(float* d_matrix);
void FreeMatrix(float* d_matrix);
int bitCount (int* n);


void FindSphereCharacteristics(float* events, float* clusters, int finalClusterCount, float* volume, float* density, float* occupancy, int);
void FindBoxCharacteristics(float* events, float* clusters, int finalClusterCount, float* volume, float* density, float* occupancy, int);

void FindCharacteristics(float* events, float* clusters, int finalClusterCount, float averageTime, float mdlTime, int numIterations, char* inFileName, clock_t total_start);


void ReportResults(float* events, float* clusters, int count, char* inFileName);

void ReportSummary(float* clusters, int count, char* inFileName, float averageTime, float mdlTime, int iterations, clock_t total_start);


#endif
