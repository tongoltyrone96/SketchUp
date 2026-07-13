module SketchDraw
  module Toolbar
    def self.build
      tb = UI::Toolbar.new('SketchDraw')

      [
        ['Paper',  'paper',  'Select paper size / template',    -> { PaperFrame.show_dialog }],
        ['Scale',  'scale',  'Set drawing scale (1:100 etc.)',  -> { ScaleTool.activate }],
        ['Dim',    'dim',    'Place dimension line',            -> { DimensionTool.activate }],
        ['Text',   'text',   'Place text',                      -> { TextTool.activate }],
        ['Arrow',  'arrow',  'Place arrow + label',             -> { ArrowTool.activate }],
        ['Image',  'image',  'Import JPEG / PNG image',         -> { ImageImport.run }],
        ['PDF',    'pdf',    'Export to PDF',                   -> { PdfExport.run }],
        ['Front',  'front',  'Bring selection to front',        -> { DrawOrder.bring_to_front }],
        ['Back',   'back',   'Send selection to back',          -> { DrawOrder.send_to_back }],
        ['2D',     'lock2d', 'Toggle 2D lock (no 3D orbit)',    -> { Lock2D.toggle }]
      ].each do |name, icon, tip, action|
        cmd = UI::Command.new(name) { action.call }
        cmd.tooltip    = tip
        cmd.small_icon = icon_path("#{icon}_16.png")
        cmd.large_icon = icon_path("#{icon}_24.png")
        tb.add_item(cmd)
      end

      tb.restore
    end

    def self.icon_path(filename)
      File.join(SketchDraw::PLUGIN_DIR, 'icons', filename)
    end
  end
end
