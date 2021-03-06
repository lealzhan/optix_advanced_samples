/* 
 * Copyright (c) 2016, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <optix.h>
#include <optix_math.h>
#include <optixu/optixu_matrix.h>
#include <optixu/optixu_aabb.h>
#include "helpers.h"
#include "sunsky.cuh"
#include "intersection_refinement.h"

/******************************************************************************\
 * 
 * Common variables and helper functions 
 *
\******************************************************************************/



rtDeclareVariable(optix::Ray, ray, rtCurrentRay, );
rtDeclareVariable(float3, geometric_normal, attribute geometric_normal, ); 
rtDeclareVariable(float3, shading_normal, attribute shading_normal, ); 


   

/******************************************************************************\
 * 
 * Heightfield geometry programs
 *
\******************************************************************************/

rtDeclareVariable(float3,  boxmin, , );
rtDeclareVariable(float3,  boxmax, , );
rtDeclareVariable(float3,  cellsize, , );
rtDeclareVariable(float3,  inv_cellsize, , );
rtDeclareVariable(int2,    ncells, , );

rtBuffer<float,  2>  heights;
rtBuffer<float4, 2>  normals;
rtDeclareVariable(float3, texcoord, attribute texcoord, ); 
rtDeclareVariable(float3, back_hit_point, attribute back_hit_point, );
rtDeclareVariable(float3, front_hit_point, attribute front_hit_point, );


__device__ float3 computeNormal( int Lu, int Lv, float3 hitpos )
{
  float2 C = make_float2((hitpos.x - boxmin.x) * inv_cellsize.x,
                         (hitpos.z - boxmin.z) * inv_cellsize.z);
  float2 uv = C - make_float2(Lu, Lv);

  float3 n00 = make_float3( normals[make_uint2(Lu,   Lv)  ] );
  float3 n01 = make_float3( normals[make_uint2(Lu,   Lv+1)] );
  float3 n10 = make_float3( normals[make_uint2(Lu+1, Lv)  ] );
  float3 n11 = make_float3( normals[make_uint2(Lu+1, Lv+1)] );

  return optix::bilerp( n00, n10, n01, n11, uv.x, uv.y ); 
}

RT_PROGRAM void intersect(int primIdx)
{
  // Step 1 is setup (handled in CPU code)

  // Step 2 - transform ray into grid space and compute ray-box intersection
  float3 t0   = (boxmin - ray.origin)/ray.direction;
  float3 t1   = (boxmax - ray.origin)/ray.direction;
  float3 near = fminf(t0, t1);
  float3 far  = fmaxf(t0, t1);
  float tnear = fmaxf( near );
  float tfar  = fminf( far );

  if(tnear >= tfar)
    return;
  if(tfar < 1.e-6f)
    return;
  tnear = max(tnear, 0.f);
  tfar  = min(tfar,  ray.tmax);

  // Step 3
  uint2 nnodes;
  nnodes.x = heights.size().x;
  nnodes.y = heights.size().y;
  float3 L = (ray.origin + tnear * ray.direction - boxmin) * inv_cellsize;
  int Lu = min(__float2int_rz(L.x), nnodes.x-2);
  int Lv = min(__float2int_rz(L.z), nnodes.y-2);

  // Step 4
  float3 D = ray.direction * inv_cellsize;
  int diu = D.x>0?1:-1;
  int div = D.z>0?1:-1;
  int stopu = D.x>0?(int)(nnodes.x)-1:-1;
  int stopv = D.z>0?(int)(nnodes.y)-1:-1;

  // Step 5
  float dtdu = abs(cellsize.x/ray.direction.x);
  float dtdv = abs(cellsize.z/ray.direction.z);

  // Step 6
  float far_u = (D.x>0.0f?Lu+1:Lu) * cellsize.x + boxmin.x;
  float far_v = (D.z>0.0f?Lv+1:Lv) * cellsize.z + boxmin.z;

  // Step 7
  float tnext_u = (far_u - ray.origin.x)/ray.direction.x;
  float tnext_v = (far_v - ray.origin.z)/ray.direction.z;

  // Step 8
  float yenter = ray.origin.y + tnear * ray.direction.y;
  while(tnear < tfar){
    float texit = min(tnext_u, tnext_v);
    float yexit = ray.origin.y + texit * ray.direction.y;

    // Step 9
    float d00 = heights[make_uint2(Lu,   Lv)  ];
    float d01 = heights[make_uint2(Lu,   Lv+1)];
    float d10 = heights[make_uint2(Lu+1, Lv)  ];
    float d11 = heights[make_uint2(Lu+1, Lv+1)];
    float datamin = min(min(d00, d01), min(d10, d11));
    float datamax = max(max(d00, d01), max(d10, d11));
    float ymin = min(yenter, yexit);
    float ymax = max(yenter, yexit);

    if(ymin <= datamax && ymax >= datamin) {

      float3 p00 = make_float3( boxmin.x + Lu*cellsize.x, d00, boxmin.z + Lv*cellsize.z );
      float3 p11 = make_float3( p00.x + cellsize.x,       d11, p00.z + cellsize.z ); 
      float3 p01 = make_float3( p00.x,                    d01, p11.z ); 
      float3 p10 = make_float3( p11.x,                    d10, p00.z ); 
      
      bool done = false;
      float3 n;
      float  t, beta, gamma;

      if( intersect_triangle( ray, p00, p11, p10, n, t, beta, gamma ) ) {
        if(rtPotentialIntersection(t)) {
          geometric_normal = normalize( n );
          shading_normal   = computeNormal( Lu, Lv, ray.origin+t*ray.direction );
          refine_and_offset_hitpoint( ray.origin + t*ray.direction, ray.direction,
                                      geometric_normal, p00,
                                      back_hit_point, front_hit_point );
          if(rtReportIntersection(0)) {
            done = true;
          }
        }
      }
      
      if( intersect_triangle( ray, p00, p01, p11, n, t, beta, gamma ) ) {
        if(rtPotentialIntersection(t)) {
          geometric_normal =  normalize( n );
          shading_normal   = computeNormal( Lu, Lv, ray.origin+t*ray.direction );
          refine_and_offset_hitpoint( ray.origin + t*ray.direction, ray.direction,
                                      geometric_normal, p00,
                                      back_hit_point, front_hit_point );

          if( rtReportIntersection( 0 ) ) {
            done = true;
          }
        }
      }
      if( done ) return;
    }

    // Step 11
    yenter = yexit;
    if(tnext_u < tnext_v){
      Lu += diu;
      if(Lu == stopu)
        break;
      tnear = tnext_u;
      tnext_u += dtdu;
    } else {
      Lv += div;
      if(Lv == stopv)
        break;
      tnear = tnext_v;
      tnext_v += dtdv;
    }
  }
}


RT_PROGRAM void bounds (int, float result[6])
{
  optix::Aabb* aabb = (optix::Aabb*)result;
  aabb->set(boxmin, boxmax);
}


/******************************************************************************\
 * 
 * Ocean water material programs.
 * Note: these do not shoot secondary rays, they just apply a local shading model
 * based on Fresnel reflection and a sky dome.
 *
 *
\******************************************************************************/

rtDeclareVariable(float3,       cutoff_color, , );
rtDeclareVariable(float,        fresnel_exponent, , );
rtDeclareVariable(float,        fresnel_minimum, , );
rtDeclareVariable(float,        fresnel_maximum, , );
rtDeclareVariable(float,        refraction_index, , );
rtDeclareVariable(float3,       refraction_color, , );
rtDeclareVariable(float3,       reflection_color, , );

struct PerRayData_radiance
{
  float3 result;
  float importance;
  int depth;
};

rtDeclareVariable(PerRayData_radiance, prd_radiance, rtPayload, );

__device__ __inline__ float3 oceanQuerySkyModel( bool CEL, float3 ray_direction )
{
  const float d_dot_up = dot( ray_direction, sky_up );
  if( d_dot_up < 0.0f )
  {
    float3 clamped_dir = normalize( cross( ray_direction, sky_up ) );
    clamped_dir = normalize( cross( sky_up, clamped_dir ) );
    return querySkyModel( CEL, clamped_dir);
  }
  else
  {
    return querySkyModel( CEL, ray_direction );
  }
}


RT_PROGRAM void closest_hit_radiance()
{
  const float3 i = ray.direction;     // incident direction

  float reflection = fresnel_maximum;
  float3 result = make_float3(0.0f);
  
  // refraction
  {
    float3 t = make_float3( 0.0f ); // transmission direction
    if ( refract(t, i, shading_normal, refraction_index) )
    {
      // check for external or internal reflection
      float cos_theta = dot(i, shading_normal);
      if (cos_theta < 0.0f) 
        cos_theta = -cos_theta;
      else 
        cos_theta = dot(t, shading_normal);

      reflection = fresnel_schlick(cos_theta, fresnel_exponent, fresnel_minimum, fresnel_maximum);
      if( dot( i, geometric_normal ) < 0.0f )
          result += (1.0f - reflection) * refraction_color * cutoff_color; 
      else
          result += (1.0f - reflection) * refraction_color * oceanQuerySkyModel( false, t );
    }
    // else TIR
  } 

  // reflection
  float3 color = cutoff_color;
  if( dot( i, geometric_normal ) < 0.0f )
  {
    float3 r = reflect(i, shading_normal);
    color = oceanQuerySkyModel( false, r );
  }

  result += reflection * reflection_color * color;

  prd_radiance.result = result;
}


/******************************************************************************\
 * 
 * Ocean sunsky miss program
 *
\******************************************************************************/



RT_PROGRAM void miss()
{
  prd_radiance.result = oceanQuerySkyModel( prd_radiance.depth == 0 , ray.direction );
}   

