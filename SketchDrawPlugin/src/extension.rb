require_relative 'state'
require_relative 'toolbar'
require_relative 'tools/paper_frame'
require_relative 'tools/title_block_editor'
require_relative 'tools/scale_tool'
require_relative 'tools/dimension_tool'
require_relative 'tools/text_tool'
require_relative 'tools/edit_tool'
require_relative 'tools/arrow_tool'
require_relative 'tools/image_import'
require_relative 'tools/pdf_export'
require_relative 'tools/draw_order'
require_relative 'tools/lock_2d'

module SketchDraw
  def self.version_ok?
    Sketchup.version.to_f >= MIN_VERSION
  end

  def self.boot
    unless version_ok?
      UI.messagebox(
        "SketchDraw requires SketchUp 2019 or later.\nCurrent: #{Sketchup.version}",
        MB_OK
      )
      return
    end
    Toolbar.build
    EditTool.install_observer

    menu = UI.menu('Extensions').add_submenu('SketchDraw')
    menu.add_item('Show Toolbar') { Toolbar.show_toolbar }
  end

  boot
end
