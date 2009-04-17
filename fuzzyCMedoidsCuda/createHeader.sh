#! /bin/sh

NUM_CLUSTERS=$1
NUM_THREADS=$2
NUM_DATA_POINTS=$3
NUM_DIMENSIONS=$4
STEP_SIZE=$5
BLOCK_DATA_SIZE=$6
BLOCK_DATA_SIZE_LAST=$7
DIST_MEASURE=$8

cp cmedoids.in.h cmedoids.h
perl -pi -e "s/#define NUM_CLUSTERS VALUE/#define NUM_CLUSTERS $NUM_CLUSTERS/g" cmedoids.h
perl -pi -e "s/#define NUM_THREADS VALUE/#define NUM_THREADS $NUM_THREADS/g" cmedoids.h
perl -pi -e "s/#define NUM_DATA_POINTS VALUE/#define NUM_DATA_POINTS $NUM_DATA_POINTS/g" cmedoids.h
perl -pi -e "s/#define NUM_DIMENSIONS VALUE/#define NUM_DIMENSIONS $NUM_DIMENSIONS/g" cmedoids.h
perl -pi -e "s/#define STEP_SIZE VALUE/#define STEP_SIZE $STEP_SIZE/g" cmedoids.h
perl -pi -e "s/#define DIST_MEASURE VALUE/#define DIST_MEASURE $DIST_MEASURE/g" cmedoids.h
perl -pi -e "s/#define BLOCK_DATA_SIZE VALUE/#define BLOCK_DATA_SIZE $BLOCK_DATA_SIZE/g" cmedoids.h
perl -pi -e "s/#define BLOCK_DATA_SIZE_LAST VALUE/#define BLOCK_DATA_SIZE_LAST $BLOCK_DATA_SIZE_LAST/g" cmedoids.h