#ifndef __DENOISING_REFLECTIONS_HLSL__
#define __DENOISING_REFLECTIONS_HLSL__
#include "pbr_util.hlsl"
#include "rand_util.hlsl"

Texture2D input_texture : register(t0);
Texture2D accum_texture : register(t1);
Texture2D ray_raw_texture : register(t2);
Texture2D dir_hitT_texture : register(t3);
Texture2D albedo_roughness_texture : register(t4);
Texture2D normal_metallic_texture : register(t5);
Texture2D motion_texture : register(t6); // xy: motion, z: fwidth position, w: fwidth normal
Texture2D linear_depth_texture : register(t7);
Texture2D world_position_texture : register(t8);
RWTexture2D<float4> output_texture : register(u0);

SamplerState point_sampler : register(s0);
SamplerState linear_sampler : register(s0);

cbuffer CameraProperties : register(b0)
{
	float4x4 view;
	float4x4 projection;
	float4x4 inv_projection;
	float4x4 inv_view;
	float4x4 prev_projection;
	float4x4 prev_view;
	uint is_hybrid;
	uint is_path_tracer;
	uint is_ao;
	uint has_shadows;
	uint has_reflections;
	float3 padding;
};

cbuffer DenoiserSettings : register(b1)
{
	float integration_alpha;
	float variance_clipping_sigma;
	float n_phi;
	float z_phi;
};

float3 unpack_position(float2 uv, float depth, float4x4 proj_inv, float4x4 view_inv) {
	const float4 ndc = float4(uv * 2.0f - 1.f, depth, 1.0f);
	const float4 pos = mul( view_inv, mul(proj_inv, ndc));
	return (pos / pos.w).xyz;
}

float3 unpack_position_linear_depth(float2 uv, float depth, float4x4 proj_inv, float4x4 view_inv) {
	const float4 ndc = float4(uv * 2.0f - 1.f, 1.f, 1.0f);
	const float4 pos = mul( view_inv, mul(proj_inv, ndc));
	return normalize((pos / pos.w).xyz) * depth;
}

float3 OctToDir(uint octo)
{
	float2 e = float2( f16tof32(octo & 0xFFFF), f16tof32((octo>>16) & 0xFFFF) ); 
	float3 v = float3(e, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0)
		v.xy = (1.0 - abs(v.yx)) * (step(0.0, v.xy)*2.0 - (float2)(1.0));
	return normalize(v);
}

float Luminance(float3 color)
{
	return (color.r + color.r + color.b + color.g + color.g + color.g) / 6.0;
}

uint DirToOct(float3 normal)
{
	float2 p = normal.xy * (1.0 / dot(abs(normal), 1.0.xxx));
	float2 e = normal.z > 0.0 ? p : (1.0 - abs(p.yx)) * (step(0.0, p)*2.0 - (float2)(1.0));
	return (asuint(f32tof16(e.y)) << 16) + (asuint(f32tof16(e.x)));
}

void FetchNormalAndLinearZ(in int2 ipos, out float3 norm, out float2 zLinear)
{
	norm = normal_metallic_texture[ipos].xyz;
	zLinear = linear_depth_texture[ipos].xy;
}

float NormalDistanceCos(float3 n1, float3 n2, float power)
{
	return pow(max(0.0, dot(n1, n2)), power);
}

float ComputeWeightNoLuminance(float depth_center, float depth_p, float phi_depth, float3 normal_center, float3 normal_p)
{
	const float w_normal    = NormalDistanceCos(normal_center, normal_p, 128.f);
	const float w_z         = abs(depth_center - depth_p) / phi_depth;

	return exp(-max(w_z, 0.0)) * w_normal;
}

float ComputeWeight(
	float depth_center, float depth_p, float phi_depth,
	float3 normal_center, float3 normal_p, float norm_power, 
	float luminance_direct_center, float luminance_direct_p, float phi_direct)
{
	const float w_normal    = NormalDistanceCos(normal_center, normal_p, norm_power);
	const float w_z         = (phi_depth == 0) ? 0.0f : abs(depth_center - depth_p) / phi_depth;
	const float w_l_direct   = abs(luminance_direct_center - luminance_direct_p) / phi_direct;

	const float w_direct   = exp(0.0 - max(w_l_direct, 0.0)   - max(w_z, 0.0)) * w_normal;

	return w_direct;
}

bool LoadPrevData(float2 screen_coord, out float4 prev_direct, out float history_length)
{
	float2 screen_size = float2(0.f, 0.f);
	input_texture.GetDimensions(screen_size.x, screen_size.y);

	float2 uv = screen_coord / screen_size;

	float4 motion = motion_texture.SampleLevel(point_sampler, uv, 0);
	float2 q_uv = uv - motion.xy;

	float2 prev_coords = q_uv * screen_size;

	float4 depth = depth_texture[prev_coords];
	float3 normal = OctToDir(asuint(depth.w));

	prev_direct = float4(0, 0, 0, 0);
	prev_moments = float2(0, 0);

	bool v[4];
	const float2 pos_prev = prev_coords;
	int2 offset[4] = {int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1)};

	bool valid = false;
	[unroll]
	for(int sample_idx = 0; sample_idx < 4; ++sample_idx)
	{
		int2 loc = int2(pos_prev) + offset[sample_idx];
		float4 depth_prev = prev_depth_texture[loc];
		float3 normal_prev = OctToDir(asuint(depth_prev.w));

		v[sample_idx] = IsReprojectionValid(loc, depth.z, depth_prev.x, depth.y, normal, normal_prev, motion.w);

		valid = valid || v[sample_idx];
	}

	if(valid)
	{
		float sum_weights = 0;
		float x = frac(pos_prev.x);
		float y = frac(pos_prev.y);

		float weights[4] = {(1 - x) * (1 - y),
							x * (1 - y),
							(1 - x) * y,
							x * y };

		[unroll]
		for(int sample_idx = 0; sample_idx < 4; ++sample_idx)
		{
			int2 loc = int2(pos_prev) + offset[sample_idx];

			prev_direct += weights[sample_idx] * prev_input_texture[loc] * float(v[sample_idx]);
			prev_moments += weights[sample_idx] * prev_moments_texture[loc] * float(v[sample_idx]);
			sum_weights += weights[sample_idx] * float(v[sample_idx]);
		}

		valid = (sum_weights >= 0.01);
		prev_direct = lerp(float4(0, 0, 0, 0), prev_direct / sum_weights, valid);
		prev_moments = lerp(float2(0, 0), prev_moments / sum_weights, valid);

	}
	if(!valid)
	{
		float cnt = 0.0;

		const int radius = 1;
		for(int y = -radius; y <= radius; ++y)
		{
			for(int x = -radius; x <= radius; ++x)
			{
				int2 p = prev_coords + int2(x, y);
				float4 depth_filter = prev_depth_texture[p];
				float3 normal_filter = OctToDir(asuint(depth_filter.w));

				if(IsReprojectionValid(prev_coords, depth.z, depth_filter.x, depth.y, normal, normal_filter, motion.w))
				{
					prev_direct += prev_input_texture[p];
					prev_moments += prev_moments_texture[p];
					cnt += 1.0;
				}
			}
		}

		valid = cnt > 0;
		prev_direct /= lerp(1, cnt, cnt > 0);
		prev_moments /= lerp(1, cnt, cnt > 0);
	}

	if(valid)
	{
		history_length = in_hist_length_texture[prev_coords].r;
	}
	else
	{
		prev_direct = float4(0, 0, 0, 0);
		prev_moments = float2(0, 0);
		history_length = 0;
	}

	return valid;
}

[numthreads(16, 16, 1)]
void temporal_denoiser_cs(int3 dispatch_thread_id : SV_DispatchThreadID)
{
	float2 screen_coord = float2(dispatch_thread_id.xy);
	float2 screen_size = float2(0, 0);
	output_texture.GetDimensions(screen_size.x, screen_size.y);

	float2 uv = screen_coord / screen_size;

	float4 accum_color = float4(0, 0, 0, 0);
	float history = 0;

	bool valid = LoadPrevData(screen_coord, accum_color, history);

	float4 input_color = input_texture[screen_coord];

	float pdf = ray_raw_texture.SampleLevel(point_sampler, uv, 0).w;

	float3 ray_dir = dir_hitT_texture.SampleLevel(point_sampler, uv, 0).xyz;
	
    float3 world_pos = world_position_texture[screen_coord].xyz;

    float3 cam_pos = float3(inv_view[0][3], inv_view[1][3], inv_view[2][3]);

	float3 V = normalize(cam_pos - world_pos);

	float3 N = normal_metallic_texture[screen_coord].xyz;

	float roughness = albedo_roughness_texture[screen_coord].w;

	float weight = brdf_weight(V, ray_dir, N, roughness) / pdf;

	history += 1;

	float3 output = (prev_color.xyz * (history - 1) + input_color.xyz) / history;

	output_texture[screen_coord] = float4(output.xyz, history);
}

[numthreads(16, 16, 1)]
void spatial_denoiser_cs(int3 dispatch_thread_id : SV_DispatchThreadID)
{
    float2 screen_coord = float2(dispatch_thread_id.xy);

    float2 screen_size = float2(0, 0);
    output_texture.GetDimensions(screen_size.x, screen_size.y);

	
    float2 uv = screen_coord / screen_size;

    float3 world_pos = world_position_texture[screen_coord].xyz;
    float3 center_pos = world_position_texture[screen_size / 4].xyz;
    float3 cam_pos = float3(inv_view[0][3], inv_view[1][3], inv_view[2][3]);

	float3 center_normal = float3(0, 0, 0);
	float2 center_depth = float2(0, 0);

	FetchNormalAndLinearZ(screen_size / 4.0, center_normal, center_depth);

	float3 p_normal = float3(0, 0, 0);
	float2 p_depth = float2(0, 0);

	FetchNormalAndLinearZ(screen_coord, p_normal, p_depth);

    float3 V = normalize(cam_pos - world_pos);

    float3 center_V = normalize(cam_pos - center_pos);
    float3 N = normalize(normal_metallic_texture[screen_size / 4].xyz);

    float3 L = reflect(-center_V, N);

    float roughness = max(albedo_roughness_texture[screen_size / 4].a, 1e-3);
	
	float pdf = ray_raw_texture.SampleLevel(point_sampler, uv, 0).a;

	float center_weight = brdf_weight(center_V, L, N, roughness);

	float weight = (brdf_weight(V, L, N, roughness) / center_weight);// * 
	ComputeWeightNoLuminance(center_depth.x, p_depth.x, max(center_depth.y, 1e-8) * length(screen_coord - screen_size / 4.0), center_normal, p_normal);
	
	int kernel = 1;

	float kernel_width = 20.0;
	float kernel_height = 20.0;

	float2 kernel_bottom_left = float2(-kernel_width, -kernel_height);
	float2 kernel_bottom_right = float2(kernel_width, -kernel_height);
	float2 kernel_top_left = float2(-kernel_width, kernel_height);
	float2 kernel_top_right = float2(kernel_width, kernel_height);

	float2x2 kernel_shear = {1, 1, 0, 1};

	kernel_bottom_left = mul(kernel_shear, kernel_bottom_left);
	kernel_bottom_right = mul(kernel_shear, kernel_bottom_right);
	kernel_top_left = mul(kernel_shear, kernel_top_left);
	kernel_top_right = mul(kernel_shear, kernel_top_right);

	kernel_bottom_left += screen_size / 4.f;
	kernel_bottom_right += screen_size / 4.f;
	kernel_top_left += screen_size / 4.f;
	kernel_top_right += screen_size / 4.f;

	//kernel = screen_coord.x > kernel_bottom_left.x && screen_coord.y > kernel_bottom_left.y;
	//kernel = kernel && screen_coord.x < kernel_top_right.x && screen_coord.y < kernel_top_right.y;

	float2 line_1 = float2(((screen_size.y - kernel_top_left.y) - (screen_size.y - kernel_bottom_left.y)) / (kernel_top_left.x - kernel_bottom_left.x), 0.0);
	line_1.y = (screen_size.y - kernel_top_left.y) - line_1.x * kernel_top_left.x;
	float2 line_2 = float2(((screen_size.y - kernel_top_right.y) - (screen_size.y - kernel_bottom_right.y)) / (kernel_top_right.x - kernel_bottom_right.x), 0.0);
	line_2.y = (screen_size.y - kernel_top_right.y) - line_1.x * kernel_top_right.x;
	float2 line_3 = float2(((screen_size.y - kernel_bottom_right.y) - (screen_size.y - kernel_bottom_left.y)) / (kernel_bottom_right.x - kernel_bottom_left.x), 0.0);
	line_3.y = (screen_size.y - kernel_bottom_right.y) - line_1.x * kernel_bottom_right.x;
	
	kernel = kernel && line_1.x * screen_coord.x - (screen_size.y - screen_coord.y) + line_1.y == 0;
	//kernel = kernel || line_2.x * screen_coord.x - (screen_size.y - screen_coord.y) + line_2.y == 0;
	//kernel = kernel && line_3.x * screen_coord.x - (screen_size.y - screen_coord.y) + line_3.y == 0;
	//kernel = screen_coord.y < kernel_bottom_right.y;

	if(pdf<0.0)
	{
		output_texture[screen_coord] = input_texture[screen_coord];
		return;
	}
	else
	{
    	float4 output = lerp(input_texture[screen_coord], float4(0, 0, 1, 1), min(weight, 1.0));
		output_texture[screen_coord] = output + kernel * float4(0, 1, 0, 0);
		//return;
	}
	//output_texture[screen_coord] = albedo_roughness_texture[screen_coord].a;

	center_normal = p_normal;
	center_depth = p_depth;

	N = center_normal.xyz;
	L = reflect(-V, N);
	roughness = max(albedo_roughness_texture[screen_coord].a, 1e-2);

	float weights = 1.0;
	float4 accum = input_texture[screen_coord];

	const int kernel_size = 1;//5 + 31 * roughness;
	for(int x = -floor(kernel_size/2); x <= floor(kernel_size/2); ++x)
	{
		for(int y = -floor(kernel_size/2); y <= floor(kernel_size/2); ++y)
		{
			float2 location = screen_coord + float2(x, y);

			float pdf = ray_raw_texture.SampleLevel(point_sampler, uv, 0).w;

			if(pdf <= 0 || location.x < 0 || location.x >= screen_size.x || location.y < 0 || location.y >= screen_size.y)
			{
				
			}
			else
			{
				float4 color = input_texture[location];

				bool4 nan = isnan(color);
				if(nan.x == true || nan.y == true || nan.z == true || nan.w == true)
				{
					output_texture[screen_coord] = float4(1, 0, 0, 1);
					return;
				}

				float3 world_pos = world_position_texture[location].xyz;
				float3 V = normalize(cam_pos - world_pos);

				float3 p_normal = float3(0.0, 0.0, 1.0);
				float2 p_depth = float2(0.0, 0.0);

				FetchNormalAndLinearZ(location, p_normal, p_depth);

				float phi_depth = max(center_depth.y, 1e-8) * length(location - screen_coord);

				float weight = max(brdf_weight(V, L, N, roughness), 1e-5) * 
				max(ComputeWeightNoLuminance(center_depth.x, p_depth.x, phi_depth, center_normal, p_normal), 1e-5);

				weight *= x!=0 || y!=0;

				weights += weight;
				accum += color * weight;
			}
		}
	}

	output_texture[screen_coord] = accum / weights;
}

#endif