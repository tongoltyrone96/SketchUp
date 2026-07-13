require 'sketchup.rb'
require 'extensions.rb'

module SketchDraw
  PLUGIN_ID   = 'SketchDrawPlugin'.freeze
  PLUGIN_DIR  = File.dirname(__FILE__).freeze
  PLUGIN_VER  = '1.0.0'.freeze
  MIN_VERSION = 19

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
