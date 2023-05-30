#include "passthrough.hpp"
#include <cuda_runtime.h>
#include <cassert>
#include <stdint.h>

typedef enum {
    PASSTHROUGH = 0,
    VOXELGRID = 1,
} FilterType_t;

typedef struct {
    FilterType_t type;
    //0=x,1=y,2=z
    //type PASSTHROUGH
    int dim;
    float upFilterLimits;
    float downFilterLimits;
    bool limitsNegative;
    //type VOXELGRID
    float voxelX;
    float voxelY;
    float voxelZ;

} FilterParam_t;


class cudaFilter
{
public:
    cudaFilter(cudaStream_t stream = 0);
    ~cudaFilter(void);
    /*
    Input:
        source: data pointer for points cloud
        nCount: count of points in cloud_in
    Output:
        output: data pointer which has points filtered by CUDA
        countLeft: count of points in output
    */
    int set(FilterParam_t param);
    int filter(void *output, unsigned int *countLeft, void *source, unsigned int nCount);

    void *m_handle = NULL;
};

__forceinline__ __device__
bool inside_box(float3 p, float3 min, float3 max)
{
    return p.x >= min.x && p.x <= max.x &&
           p.y >= min.y && p.y <= max.y &&
           p.z >= min.z && p.z <= max.z;
}

__forceinline__ __device__
bool inside_range(float3 p, float min_dist, float max_dist)
{
    float dist = p.x * p.x + p.y * p.y + p.z * p.z;
    return dist >= min_dist * min_dist && dist <= max_dist * max_dist;
}

/**
 * Filter out points that are not within the specified range.
 * The range is specified as a minimum and maximum distance from the origin.
 * Input cloud can be arbitrary point step size but output will be float4. 
 */
__global__
void krnl_passthrough_filter(
    void* cloud,
    uint32_t num_points, 
    uint32_t point_step, 
    float min_dist,
    float max_dist,
    float3 min,
    float3 max,
    bool invert_bounding_box,
    bool invert_distance,
    float* cloud_filtered,
    uint32_t* num_points_filtered)
{
    uint32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= num_points) return;

    float4* p = (float4*) ((int8_t*)cloud + (point_step * idx)); // int8_t* to avoid pointer arithmetic but we go byte steps
    float3 p3 = make_float3(p->x, p->y, p->z);

    bool is_inside_range = inside_range(p3, min_dist, max_dist);
    if (invert_distance) is_inside_range = !is_inside_range;
    
    bool is_inside_box = inside_box(p3, min, max);
    if (invert_bounding_box) is_inside_box = !is_inside_box;

    if (!is_inside_range || !is_inside_box)
        return;

    uint32_t idx_filtered = atomicAdd(num_points_filtered, 1);
    cloud_filtered[idx_filtered + 0] = p->x;
    cloud_filtered[idx_filtered + 1] = p->y;
    cloud_filtered[idx_filtered + 2] = p->z;
    cloud_filtered[idx_filtered + 3] = p->w;
}

extern "C"
{
void cupcl_passthrough_filter(
    void* stream,
    void* cloud,
    uint32_t num_points, 
    uint32_t point_step, 
    float min_dist,
    float max_dist,
    float min_x,
    float min_y,
    float min_z,
    float max_x,
    float max_y,
    float max_z,
    bool invert_bounding_box,
    bool invert_distance,
    float* cloud_filtered,
    uint32_t* num_points_filtered)
{
constexpr size_t THREADS_PER_BLOCK = 1024;
size_t BLOCKS = std::ceil((float)num_points / THREADS_PER_BLOCK);
cudaStream_t s = (cudaStream_t)stream;
krnl_passthrough_filter<<<BLOCKS, THREADS_PER_BLOCK, 0, s>>>(
    cloud,
    num_points,
    point_step,
    min_dist,
    max_dist,
    make_float3(min_x, min_y, min_z),
    make_float3(max_x, max_y, max_z),
    invert_bounding_box,
    invert_distance,
    cloud_filtered,
    num_points_filtered);
    cudaStreamSynchronize(s);
}


void* cupcl_init_voxel_filter(void* stream, float voxel_size_x, float voxel_size_y, float voxel_size_z)
{
    cudaStream_t s = (cudaStream_t)stream;
    cudaFilter* filter = new cudaFilter(s);
    FilterParam_t param;
    param.type = VOXELGRID;
    param.voxelX = voxel_size_x;
    param.voxelY = voxel_size_y;
    param.voxelZ = voxel_size_z;
    filter->set(param);
    return 0;
}

uint32_t cupcl_voxel_filter(void* filter_instance, void* stream, float* input, uint32_t input_n, float* filtered)
{
    cudaStream_t s = (cudaStream_t)stream;
    cudaFilter* f = (cudaFilter*)filter_instance;
    uint32_t filtered_n = 0;
    int32_t ret = f->filter(filtered, &filtered_n, input, input_n);
    assert(ret == 0);
    cudaStreamSynchronize(s);
    return filtered_n;
}

void cupcl_free_voxel_filter(void* filter_instance)
{
    if (filter_instance == NULL)
        return;
    cudaFilter* f = (cudaFilter*)filter_instance;
    delete f;
}
}