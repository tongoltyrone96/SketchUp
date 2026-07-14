module SketchDraw
  module Toolbar
    @dialog = nil

    TOOLBAR_HTML = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
      <meta charset="utf-8">
      <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body {
          width: 100%; height: 100%;
          background: #1a1a1a;
          overflow: hidden;
          font-family: Arial, sans-serif;
        }
        .grid {
          display: grid;
          grid-template-columns: repeat(5, 1fr);
          grid-template-rows: repeat(2, 1fr);
          gap: 5px;
          padding: 6px;
          height: 100%;
        }
        .btn {
          border: none;
          border-radius: 4px;
          color: #fff;
          font-size: 12px;
          font-weight: bold;
          cursor: pointer;
          border-bottom: 2px solid rgba(0,0,0,0.4);
          transition: filter 0.08s;
          outline: none;
        }
        .btn:hover  { filter: brightness(1.18); }
        .btn:active { transform: translateY(1px); border-bottom-width: 1px; filter: brightness(0.88); }
        #btn-paper { background: #2E7D32; }
        #btn-scale { background: #00695C; }
        #btn-dim   { background: #1565C0; }
        #btn-text  { background: #C62828; }
        #btn-arrow { background: #6A1B9A; }
        #btn-image { background: #1B5E20; }
        #btn-pdf   { background: #B71C1C; }
        #btn-front { background: #E65100; }
        #btn-back  { background: #37474F; }
        #btn-2d    { background: #263238; }
        #btn-2d.on { background: #BF360C; }
      </style>
      </head>
      <body>
      <div class="grid">
        <button class="btn" id="btn-paper"  onclick="sketchup.cmd_paper()">Paper</button>
        <button class="btn" id="btn-scale"  onclick="sketchup.cmd_scale()">Scale</button>
        <button class="btn" id="btn-dim"    onclick="sketchup.cmd_dim()">Dim</button>
        <button class="btn" id="btn-text"   onclick="sketchup.cmd_text()">Text</button>
        <button class="btn" id="btn-arrow"  onclick="sketchup.cmd_arrow()">Arrow</button>
        <button class="btn" id="btn-image"  onclick="sketchup.cmd_image()">Image</button>
        <button class="btn" id="btn-pdf"    onclick="sketchup.cmd_pdf()">PDF</button>
        <button class="btn" id="btn-front"  onclick="sketchup.cmd_front()">Front</button>
        <button class="btn" id="btn-back"   onclick="sketchup.cmd_back()">Back</button>
        <button class="btn" id="btn-2d"     onclick="sketchup.cmd_2d()">2D:Off</button>
      </div>
      <script>
      function set2DState(on) {
        var b = document.getElementById('btn-2d');
        b.textContent = on ? '2D:On' : '2D:Off';
        if (on) { b.classList.add('on'); } else { b.classList.remove('on'); }
      }
      </script>
      </body>
      </html>
    HTML

    def self.build
      @dialog = UI::HtmlDialog.new(
        dialog_title: 'SketchDraw',
        scrollable:   false,
        resizable:    false,
        width:        368,
        height:       100,
        min_width:    368,
        min_height:   100,
        style:        UI::HtmlDialog::STYLE_UTILITY
      )

      @dialog.set_html(TOOLBAR_HTML)

      @dialog.add_action_callback('cmd_paper') { |_| PaperFrame.show_dialog }
      @dialog.add_action_callback('cmd_scale') { |_| ScaleTool.activate }
      @dialog.add_action_callback('cmd_dim')   { |_| DimensionTool.activate }
      @dialog.add_action_callback('cmd_text')  { |_| TextTool.activate }
      @dialog.add_action_callback('cmd_arrow') { |_| ArrowTool.activate }
      @dialog.add_action_callback('cmd_image') { |_| ImageImport.run }
      @dialog.add_action_callback('cmd_pdf')   { |_| PdfExport.run }
      @dialog.add_action_callback('cmd_front') { |_| DrawOrder.bring_to_front }
      @dialog.add_action_callback('cmd_back')  { |_| DrawOrder.send_to_back }
      @dialog.add_action_callback('cmd_2d') do |_|
        Lock2D.toggle
        @dialog.execute_script("set2DState(#{State.lock_2d})")
      end

      @dialog.show
    end

    def self.show_toolbar
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
      else
        build
      end
    end
  end
end
