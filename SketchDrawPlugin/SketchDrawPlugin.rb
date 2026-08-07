require 'sketchup.rb'
require 'extensions.rb'

module SketchDraw
  PLUGIN_ID   = 'SketchDrawPlugin'.freeze
  PLUGIN_VER  = '5.94'.freeze
  MIN_VERSION = 19

  # Works both in dev (loader inside plugin folder) and installed via .rbz (loader at Plugins root)
  _base = File.dirname(File.expand_path(__FILE__))
  PLUGIN_DIR = if File.exist?(File.join(_base, 'src', 'extension.rb'))
                 _base
               else
                 File.join(_base, 'SketchDrawPlugin')
               end.freeze

  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new(
      'SketchDraw — Technical Drawing',
      File.join(PLUGIN_DIR, 'src', 'extension.rb')
    )
    ext.description = '2D technical drawing tools: text, dimensions, arrows, PDF export.'
    ext.version     = PLUGIN_VER
    ext.creator     = 'Your Name'
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
