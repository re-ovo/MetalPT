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
#else
#include <simd/simd.h>
#include <stdint.h>
typedef simd_float4 PTFloat4;
typedef simd_uint4 PTUInt4;
#define PT_PTR(T) uint64_t
#define PT_TEX uint64_t
#define PT_AS uint64_t
#endif

typedef struct {
    PTFloat4 position, normal, uv;
} PTVertex;

typedef struct {
    PTUInt4 indices;
} PTTriangle;

// kind: 0 diffuse, 1 gold, 2 dielectric, 3 emitter. texture: 0 white, 1 pattern.
typedef struct {
    PTFloat4 color;
    PTFloat4 optics;
    PTUInt4 flags;
} PTMaterial;

typedef struct {
    PTFloat4 origin, direction, wavelengths, wavelengthPDF, throughput, sampling;
    PTUInt4 state; // pixel, RNG, secondary terminated, previous event is delta
} PTPath;

typedef struct {
    PTFloat4 position, normal, uv;
    PTUInt4 info;
} PTHit;

typedef struct {
    PTFloat4 origin, direction, contribution;
    PTUInt4 info;
} PTShadow;

typedef struct {
    PTFloat4 eye, right, up, forward;
    PTFloat4 lightOrigin, lightU, lightV, lightNormal;
    PTUInt4 size;     // width, height, sample index, bounce
    PTUInt4 settings; // max depth, reset, dispersion, seed
    PTFloat4 display; // exposure, light area, emission, spare
} PTFrame;

typedef struct {
    PT_PTR(PTVertex) vertices;
    PT_PTR(PTTriangle) triangles;
    PT_PTR(PTMaterial) materials;
    PT_PTR(PTFloat4) cie;
    PT_PTR(PTFloat4) gold;
    PT_TEX textures[2];
    PT_AS acceleration;
} PTScene;

typedef struct {
    PT_PTR(PTPath) inputPaths;
    PT_PTR(PTPath) outputPaths;
    PT_PTR(PTHit) hits;
    PT_PTR(PTShadow) shadows;
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
_Static_assert(sizeof(PTVertex) == 48, "vertex ABI");
_Static_assert(sizeof(PTMaterial) == 48, "material ABI");
_Static_assert(sizeof(PTPath) == 112, "path ABI");
_Static_assert(sizeof(PTFrame) == 176, "frame ABI");
_Static_assert(sizeof(PTScene) == 64, "scene ABI");
_Static_assert(sizeof(PTWork) == 64, "work ABI");
#endif
#endif
