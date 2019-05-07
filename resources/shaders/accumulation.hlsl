#include "vignette.hlsl"
#include "hdr_util.hlsl"

Texture2D<float4> input : register(t0);
RWTexture2D<float4> output : register(u0);
SamplerState s0 : register(s0);

cbuffer Properties : register(b0)
{
	float frame_idx;
};


[numthreads(16, 16, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
	float2 resolution;
	input.GetDimensions(resolution.x, resolution.y);
	
	float3 color = input[DTid.xy].rgb / (frame_idx + 1);

	output[DTid.xy] = float4(color, 1);
}
