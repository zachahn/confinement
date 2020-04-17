require_relative "config/site"

using Confinement::Easier

Confinement.site.build do |assets:, layouts:, contents:, routes:|
  #    _               _
  #   /_\   ______ ___| |_ ___
  #  / _ \ (_-<_-</ -_)  _(_-<
  # /_/ \_\/__/__/\___|\__/__/
  #
  assets.init("application.js", entrypoint: true)
  assets.init("application.css", entrypoint: false)

  #  _                       _
  # | |   __ _ _  _ ___ _  _| |_ ___
  # | |__/ _` | || / _ \ || |  _(_-<
  # |____\__,_|\_, \___/\_,_|\__/__/
  #            |__/
  layouts.init("default.html.erb", renderers: [Confinement::Renderer::Erb.new])

  #  ___
  # | _ \__ _ __ _ ___ ___
  # |  _/ _` / _` / -_|_-<
  # |_| \__,_\__, \___/__/
  #          |___/
  routes["/"] = contents.init("index.html.erb") do |content|
    content.renderers = [Confinement::Renderer::Erb.new]
  end

  blog_posts = contents.init_many(%r{^posts/.*\.md.*}).filter_map do |blog_post|
    unixtime = blog_post.input_path.basename.to_s[/^\d+/]

    next if unixtime.nil?

    routes["/posts/#{unixtime}/"] = blog_post

    routes["/posts/#{unixtime}/"].renderers = [Confinement::Renderer::Erb.new]

    routes["/posts/#{unixtime}/"]
  end

  routes["/posts/"] = contents.init("posts.html.erb") do |content|
    content.locals = { blog_posts: blog_posts }
    content.renderers = [Confinement::Renderer::Erb.new]
  end

  routes["/resume/"] = contents.init("resume.html.erb") do |content|
    content.renderers = [Confinement::Renderer::Erb.new]
  end

  routes["/resume.pdf"] = contents.init("resume.tex.erb") do |content|
    content.renderers = [Confinement::Renderer::Erb.new]
  end

  routes["/view_with_layout.html"] = contents.init("view_with_layout.html.erb") do |content|
    content.layout = layouts["default.html.erb"]
    content.renderers = [Confinement::Renderer::Erb.new]
  end

  routes["/static_view_with_layout.html"] = contents.init("static_view_with_layout.html") do |content|
    content.layout = layouts["default.html.erb"]
    content.renderers = []
  end

  routes["/frontmatter.html"] = contents.init("frontmatter.html.erb")

  contents.init("_partial.html.erb")

  routes["/partial.html"] = contents.init("partial.html.erb")

  routes["view_with_embedded_asset.html"] = contents.init("view_with_embedded_asset.html.erb") do |content|
    content.renderers = [Confinement::Renderer::Erb.new]
  end

  routes["view_with_local_and_frontmatter_cooperation.html"] =
    contents.init("view_with_local_and_frontmatter_cooperation.html.erb") do |content|
      content.renderers = [Confinement::Renderer::Erb.new]
      content.locals = { how_cool: "very #{content.frontmatter[:cool]}" }
    end
end
