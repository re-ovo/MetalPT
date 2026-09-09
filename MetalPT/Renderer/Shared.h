#ifndef SPECTRAL_SHARED_H
#define SPECTRAL_SHARED_H
#ifdef __METAL_VERSION__
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace raytracing;
typedef float4 PTFloat4;
typedef uint4 PTUInt4;
#define PT_PTR(T) device T *
#define PT_TEX texture2d<float>
#define PT_AS instance_acceleration_structure
#define PT_SAMPLER sampler
#else
#include <simd/simd.h>
#include <stdint.h>
typedef simd_float4 PTFloat4;
typedef simd_uint4 PTUInt4;
#define PT_PTR(T) uint64_t
#define PT_TEX uint64_t
#define PT_AS uint64_t
#define PT_SAMPLER uint64_t
#endif

typedef struct {
    PTFloat4 position, normal, uv, tangent, color;
    PTUInt4 attributes;
} PTVertex;

typedef struct {
    PTUInt4 indices;
} PTTriangle;

typedef struct {
    PTUInt4 indices;      // texture, sampler, UV set, enabled
    PTFloat4 transform;   // offset.xy, scale.xy
    PTFloat4 rotationLOD; // cos, sin, explicit LOD, reserved
} PTTextureBinding;

// kind: diffuse, gold, dielectric, absorbing, metallic-roughness.
typedef struct {
    // coverage: alpha cutoff, transmission factor, reserved, reserved.
    PTFloat4 color, emission, optics, coverage;
    PTUInt4 flags; // kind, alpha mode, double sided, reserved
    PTTextureBinding baseColorTexture, metallicRoughnessTexture, normalTexture, emissiveTexture,
        occlusionTexture, transmissionTexture;
} PTMaterial;

typedef struct {
    // throughput.xyz is linear RGB; w is reserved and zero.
    PTFloat4 origin, direction, throughput, sampling;
    PTUInt4 state; // pixel, RNG, reserved, previous event is delta
} PTPath;

typedef struct {
    PTFloat4 position, normal, shadingNormal, uv, color, tangent;
    PTUInt4 info;
} PTHit;

typedef struct {
    PTFloat4 origin, direction, contribution;
    PTUInt4 info;
} PTShadow;

typedef struct {
    PTFloat4 eye, right, up, forward;
    PTUInt4 size;     // width, height, sample index, bounce
    PTUInt4 settings; // max depth, reset, reserved, seed
    PTFloat4 display; // exposure, reserved, reserved, validation mode
} PTFrame;

typedef struct {
    PT_PTR(PTVertex) vertices;
    PT_PTR(PTTriangle) triangles;
} PTMesh;

typedef struct {
    PTFloat4 transform[4];
    PTUInt4 indices; // mesh, material slot count, optional light index, reserved
    PT_PTR(unsigned int) materials;
} PTInstance;

typedef struct {
    PTFloat4 origin, u, v, normalArea;
    PTUInt4 indices; // material, instance, reserved, reserved
} PTLight;

typedef struct {
    PT_TEX linear, color;
} PTTexture;

typedef struct {
    PT_SAMPLER value;
} PTSampler;

typedef struct {
    PT_PTR(PTMesh) meshes;
    PT_PTR(PTInstance) instances;
    PT_PTR(PTMaterial) materials;
    PT_PTR(PTTexture) textures;
    PT_PTR(PTLight) lights;
    PT_AS acceleration;
    PT_PTR(PTSampler) samplers;
    PTUInt4 counts; // meshes, instances, textures, lights
} PTScene;

typedef struct {
    PT_PTR(PTPath) inputPaths;
    PT_PTR(PTPath) outputPaths;
    PT_PTR(PTHit) hits;
    PT_PTR(PTShadow) shadows;
    // Linear RGB in xyz; w is reserved and zero.
    PT_PTR(PTFloat4) radiance;
    PT_PTR(PTFloat4) accumulation;
#ifdef __METAL_VERSION__
    device atomic_uint *counts;
#else
    uint64_t counts;
#endif
    PT_PTR(unsigned int) indirect;
} PTWork;
#ifndef __METAL_VERSION__
_Static_assert(sizeof(PTTextureBinding) == 48, "texture binding ABI");
_Static_assert(sizeof(PTHit) == 112, "hit ABI");
_Static_assert(sizeof(PTSampler) == 8, "sampler ABI");
_Static_assert(sizeof(PTVertex) == 96, "vertex ABI");
_Static_assert(sizeof(PTMaterial) == 368, "material ABI");
_Static_assert(sizeof(PTPath) == 80, "path ABI");
_Static_assert(sizeof(PTFrame) == 112, "frame ABI");
_Static_assert(sizeof(PTScene) == 80, "scene ABI");
_Static_assert(sizeof(PTWork) == 64, "work ABI");
_Static_assert(sizeof(PTMesh) == 16, "mesh ABI");
_Static_assert(sizeof(PTInstance) == 96, "instance ABI");
_Static_assert(sizeof(PTLight) == 80, "light ABI");
_Static_assert(sizeof(PTTexture) == 16, "texture ABI");
#endif
#endif
