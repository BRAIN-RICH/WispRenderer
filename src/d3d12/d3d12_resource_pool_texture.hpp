#pragma once

#include "../resource_pool_texture.hpp"
#include "d3d12_enums.hpp"
#include "d3d12_texture_resources.hpp"
#include <DirectXMath.h>


namespace wr
{
	struct MipMapping_CB
	{
		DirectX::XMFLOAT2 TexelSize;	// 1.0 / OutMip1.Dimensions
	};

	class D3D12RenderSystem;
	class DescriptorAllocator;

	class D3D12TexturePool : public TexturePool
	{
	public:
		explicit D3D12TexturePool(D3D12RenderSystem& render_system, std::size_t size_in_bytes, std::size_t num_of_textures);
		~D3D12TexturePool() final;

		void Evict() final;
		void MakeResident() final;
		void Stage(CommandList* cmd_list) final;
		void PostStageClear() final;
		void ReleaseTemporaryResources() final;

		d3d12::TextureResource* GetTexture(uint64_t texture_id) final;

		[[nodiscard]] TextureHandle CreateCubemap(std::string_view name, uint32_t width, uint32_t height, uint32_t mip_levels, Format format, bool allow_render_dest) final;

		DescriptorAllocator* GetAllocator(DescriptorHeapType type);

		void Unload(uint64_t texture_id) final;

	protected:

		d3d12::TextureResource* LoadPNG(std::string_view path, bool srgb, bool generate_mips) final;
		d3d12::TextureResource* LoadDDS(std::string_view path, bool srgb, bool generate_mips) final;
		d3d12::TextureResource* LoadHDR(std::string_view path, bool srgb, bool generate_mips) final;
		d3d12::TextureResource* LoadPNGFromMemory(char* data, size_t size, bool srgb, bool generate_mips) final;
		d3d12::TextureResource* LoadDDSFromMemory(char* data, size_t size, bool srgb, bool generate_mips) final;
		d3d12::TextureResource* LoadHDRFromMemory(char* data, size_t size, bool srgb, bool generate_mips) final;
		d3d12::TextureResource* LoadRawFromMemory(char* data, int width, int height, bool srgb, bool generate_mips) final;

		void MoveStagedTextures();
		void GenerateMips(d3d12::TextureResource* texture, CommandList* cmd_list);
		void GenerateMips(std::vector<d3d12::TextureResource*>& const textures, CommandList* cmd_list);

		void GenerateMips_UAV(d3d12::TextureResource* texture, CommandList* cmd_list);
		void GenerateMips_BGR(d3d12::TextureResource* texture, CommandList* cmd_list);
		void GenerateMips_SRGB(d3d12::TextureResource* texture, CommandList* cmd_list);

		D3D12RenderSystem& m_render_system;

		//CPU only visible heaps used for staging of descriptors.
		//Renderer will copy the descriptor it needs to the GPU visible heap used for rendering.
		DescriptorAllocator* m_allocators[static_cast<size_t>(DescriptorHeapType::DESC_HEAP_TYPE_NUM_TYPES)];

		DescriptorAllocator* m_mipmapping_allocator;

		//Track resources that are created in one frame and destroyed after
		std::array<std::vector<d3d12::TextureResource*>, d3d12::settings::num_back_buffers> m_temporary_textures;
	};




}