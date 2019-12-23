/***************************************************************************
# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
***************************************************************************/
__import ShaderCommon;
__import Shading;
__import DefaultVS;

#include "Common.hlsl"

StructuredBuffer<Photon> gPhotonBuffer;
StructuredBuffer<RayTask> gRayTask;

Texture2D gDepthTex;
Texture2D gNormalTex;
Texture2D gDiffuseTex;
Texture2D gSpecularTex;

Texture2D gGaussianTex;

SamplerState gLinearSampler;

cbuffer PerFrameCB : register(b0)
{
    float4x4 gWvpMat;
    float4x4 gWorldMat;

    float3 gEyePosW;
    float gLightIntensity;

    float3 gLightDir;
    float gKernelPower;

    int2 taskDim;
    uint  gShowPhoton;
    float normalThreshold;

    float distanceThreshold;
    float planarThreshold;
    float gSurfaceRoughness;
    float gSplatSize;

    uint  gPhotonMode;
    float gMaxAnisotropy;
};
#define AnisotropicPhoton 0
#define IsotropicPhoton 1
#define PhotonMesh 2

struct PhotonVSIn
{
    float4 pos         : POSITION;
    float2 texC        : TEXCOORD;
    uint instanceID : SV_INSTANCEID;
    uint vertexID: SV_VERTEXID;
};

struct PhotonVSOut
{
    float4 posH : SV_POSITION;
    float2 texcoord: TEXCOORD0;
    float4 color     : COLOR;
};

int GetPhoton(int2 screenPos, inout Photon p)
{
    int offset = screenPos.y * taskDim.x + screenPos.x;
    RayTask task = gRayTask[offset];
    if (task.photonIdx == -1)
    {
        return 0;
    }
    p = gPhotonBuffer[task.photonIdx];
    return 1;
}

void ProcessPhoton(inout Photon p, float2 dir)
{
    p.dPdx *= dir.x;
    p.dPdy *= -dir.y;
}

bool isAdjacent(Photon photon0, Photon photon1, float3 axis, float normalThreshold, float distanceThreshold, float planarThreshold)
{
    float proj = abs(dot(photon1.posW - photon0.posW, axis));
    //float dist = proj / length(axis);
    float dist = length(photon1.posW - photon0.posW);
    return
        //dot(photon0.normalW, photon1.normalW) < normalThreshold &&
        dist < distanceThreshold// &&
        //dot(photon0.normalW, photon0.posW - photon1.posW) < planarThreshold
        ;
}

bool GetPhotons(int instanceID, float2 vertex, inout Photon p00, inout Photon p01, inout Photon p10, inout Photon p11, out int mask)
{
    mask = 0;
    int2 screenPos;
    screenPos.y = instanceID / taskDim.x;
    screenPos.x = instanceID - taskDim.x * screenPos.y;
    if (!GetPhoton(screenPos, p00))
    {
        return false;
    }

    //int xOffset = vertex.x;// (vertexID & 0x1) * 2 - 1;
    //int yOffset = vertex.y;// (vertexID >> 1) * 2 - 1;
    //int2 offsetArray[] = { int2(-1,1), int2(1,-1), int2(-1,-1), int2(1,1) };
    float2 offset = vertex;// offsetArray[vertexID];
    
    ProcessPhoton(p00, offset);
    if (GetPhoton(screenPos + int2(offset.x, 0), p01))
    {
        ProcessPhoton(p01, offset);
        if (isAdjacent(p00, p01, p00.dPdx, normalThreshold, distanceThreshold, planarThreshold))
            mask |= 0x1;
    }
    if (GetPhoton(screenPos + int2(0, offset.y), p10))
    {
        ProcessPhoton(p10, offset);
        if (isAdjacent(p00, p10, p00.dPdy, normalThreshold, distanceThreshold, planarThreshold))
            mask |= 0x2;
    }
    if (GetPhoton(screenPos + offset, p11))
    {
        ProcessPhoton(p11, offset);
        if (isAdjacent(p00, p11, p00.dPdx+ p00.dPdy, normalThreshold, distanceThreshold * 1.42, planarThreshold))
            mask |= 0x4;
    }

    return true;
}

void GetVertexPosInfo(Photon p00, Photon p01, Photon p10, Photon p11, int mask, out float3 posW, out float3 color)
{
    if (mask ==0)
    {
        posW = p00.posW + gSplatSize * (p00.dPdx + p00.dPdy);
        color = 0;// p00.color;
    }
    else if (mask == 1)
    {
        posW = 0.5 * (p00.posW + p01.posW) + gSplatSize * 0.5 * (p00.dPdy + p01.dPdy);
        color = 0;// float3(0, 0, 100);
    }
    else if (mask == 2)
    {
        posW = 0.5 * (p00.posW + p10.posW) + gSplatSize * 0.5 * (p00.dPdx + p10.dPdx);
        color = 0;// float3(100, 0, 100);
    }
    else if (mask == 3)
    {
        posW = 0.5 * (p10.posW + p01.posW);
        color = 0;// float3(0, 100, 0);
    }
    else if (mask == 4 || mask == 5 || mask == 6)
    {
        posW = 0.5 * (p00.posW + p11.posW);
        color = 0;// float3(100, 0, 0);// 0;
    }
    else if (mask == 7)
    {
        posW = 0.25 * (p00.posW + p01.posW + p10.posW + p11.posW);
        color.rgb = 0.25 * (p00.color + p01.color + p10.color + p11.color);
    }
    //float newDist = length(posW - p00.posW);
    //float oldDist = length(p00.dPdx + p00.dPdy) * 0.5;
    //float distRatio = newDist / oldDist;
    //float areaRatio = distRatio * distRatio;
    //color *= areaRatio;
}

bool meshScatter(int instanceID, float2 vertex, out float4 posH, out float3 color)
{
    color = 0;
    posH = float4(100, 100, 100, 1);
    Photon p00, p01, p10, p11;
    int mask = 0;
    if (!GetPhotons(instanceID, vertex, p00, p01, p10, p11, mask))
        return false;

    float3 posW;
    GetVertexPosInfo(p00, p01, p10, p11, mask, posW, color);
    posH = mul(float4(posW, 1), gWvpMat);
    return true;
}

float3 scaleVector(float3 vec, float3 axis, float2 factor)
{
    axis = normalize(axis);
    float proj = dot(vec, axis);
    vec *= factor.y;
    vec += axis * proj * (factor.x - factor.y);
    return vec;
}

PhotonVSOut photonScatterVS(PhotonVSIn vIn)
{
    PhotonVSOut vOut;
    vOut.texcoord = (vIn.pos.xz + 1) * 0.5;

    float3 tangent, bitangent, color;
    if (gPhotonMode == PhotonMesh)
    {
        float4 posH = 0;
        float3 clr = 0;
        meshScatter(vIn.instanceID, vIn.pos.xz, posH, clr);
        vOut.posH = posH;
        vOut.color = float4(clr,1);
        return vOut;
    }

    Photon p = gPhotonBuffer[vIn.instanceID];
    float3 normal = normalize(p.normalW);

    if (gPhotonMode == AnisotropicPhoton)
    {
        tangent = p.dPdx;
        bitangent = p.dPdy;
        if (dot(tangent, bitangent) < 0)
        {
            bitangent *= -1;
        }

        float3 areaVector = cross(tangent, bitangent);
        float3 sideVector = tangent + bitangent;
        float area = length(areaVector);
        float side = length(sideVector);
        float height = area / side;
        float aniso = side / height;
        if (aniso > gMaxAnisotropy)
        {
            tangent = scaleVector(tangent, sideVector, float2(gMaxAnisotropy/ aniso, 1));
            bitangent = scaleVector(bitangent, sideVector, float2(gMaxAnisotropy/aniso, 1));
        }
    }
    else if (gPhotonMode == IsotropicPhoton)
    {
        tangent = normalize(float3(normal.y, -normal.x, 0));
        bitangent = cross(tangent, normal);
        float radius = max(length(p.dPdx), length(p.dPdy));
        tangent *= radius;
        bitangent *= radius;
    }
    else
    {
        tangent = normalize(float3(normal.y, -normal.x, 0));
        bitangent = cross(tangent, normal);
    }

    tangent *= gSplatSize;
    bitangent *= gSplatSize;

    float3 areaVector = cross(tangent, bitangent);

    float3 localPoint = tangent * vIn.pos.x + bitangent * vIn.pos.z + normal * vIn.pos.y;
    vIn.pos.xyz = localPoint + p.posW;
    vOut.posH = mul(vIn.pos, gWvpMat);

    color = p.color;
    if (gShowPhoton == 2)
    {
        float3 normal = normalize(areaVector);
        vOut.color = float4(abs(dot(gLightDir, normal)), 1);
    }
    else
        vOut.color = float4(color, 1);

    return vOut;
}

float4 photonScatterPS(PhotonVSOut vOut) : SV_TARGET
{
    float depth = gDepthTex.Load(int3(vOut.posH.xy, 0)).x;
    if (gShowPhoton == 2)
    {
        if (vOut.posH.z - depth > 0.0001)
        {
            discard;
        }
        return float4(1, 0, 0, 1)* vOut.color;
    }

    if (abs(depth- vOut.posH.z) > 0.00001)
    {
        discard;
    }

    float alpha;
    if (gShowPhoton == 1 || gPhotonMode == PhotonMesh)
    {
        alpha = 1;
    }
    else
    {
        alpha = gGaussianTex.Sample(gLinearSampler, vOut.texcoord).r;
        alpha = pow(alpha, gKernelPower);
    }
    return float4(vOut.color.rgb * alpha, 1);
}
