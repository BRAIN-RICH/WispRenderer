#include "scene_graph.hpp"

#include <algorithm>

#include "../renderer.hpp"

namespace wr
{

	SceneGraph::SceneGraph(RenderSystem* render_system)
		: m_render_system(render_system), m_root(std::make_shared<Node>())
	{
	}

	SceneGraph::~SceneGraph()
	{
		RemoveChildren(GetRootNode());
	}

	//! Used to obtain the root node.
	std::shared_ptr<Node> & SceneGraph::GetRootNode()
	{
		return m_root;
	}

	//! Used to obtain the children of a node.
	std::vector<std::shared_ptr<Node>> SceneGraph::GetChildren(std::shared_ptr<Node> const & parent)
	{
		return parent ? parent->m_children : m_root->m_children;
	}

	//! Used to remove the children of a node.
	void SceneGraph::RemoveChildren(std::shared_ptr<Node> const & parent)
	{
		parent->m_children.clear();
	}

} /* wr */