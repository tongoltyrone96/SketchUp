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
          grid-template-columns: repeat(6, 1fr);
          grid-template-rows: repeat(4, 1fr);
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
        #btn-paper  { background: #2E7D32; }
        #btn-tmpl   { background: #558B2F; }
        #btn-scale  { background: #00695C; }
        #btn-dim    { background: #1565C0; }
        #btn-text   { background: #C62828; }
        #btn-arrow  { background: #6A1B9A; }
        #btn-image  { background: #1B5E20; }
        #btn-pdf    { background: #B71C1C; }
        #btn-front  { background: #E65100; }
        #btn-back   { background: #37474F; }
        #btn-2d     { background: #263238; }
        #btn-2d.on  { background: #BF360C; }
        #btn-colour { background: #455A64; position: relative; }
        #btn-colour .swatch {
          position: absolute; right: 6px; top: 50%;
          transform: translateY(-50%);
          width: 14px; height: 14px;
          border: 1px solid rgba(255,255,255,0.6);
          border-radius: 2px;
          background: #C81E1E;
        }
        #btn-thick { background: #4E342E; position: relative; }
        #btn-thick .lwbar {
          position: absolute; right: 6px; top: 50%;
          transform: translateY(-50%);
          width: 18px;
          background: #fff;
          height: 2px;
        }
        #btn-sec   { background: #283593; }
        #btn-pal   { background: #4527A0; }
        #btn-snap  { background: #006064; }
        #btn-snpl  { background: #00695C; }
        #btn-style { background: #5D4037; }
        #btn-hatch { background: #7B1FA2; }
      </style>
      </head>
      <body>
      <div class="grid">
        <button class="btn" id="btn-paper"  onclick="sketchup.cmd_paper()">Paper</button>
        <button class="btn" id="btn-tmpl"   onclick="sketchup.cmd_tmpl()">Template</button>
        <button class="btn" id="btn-scale"  onclick="sketchup.cmd_scale()">Scale</button>
        <button class="btn" id="btn-dim"    onclick="sketchup.cmd_dim()">Dim</button>
        <button class="btn" id="btn-text"   onclick="sketchup.cmd_text()">Text</button>
        <button class="btn" id="btn-arrow"  onclick="sketchup.cmd_arrow()">Arrow</button>
        <button class="btn" id="btn-image"  onclick="sketchup.cmd_image()">Image</button>
        <button class="btn" id="btn-pdf"    onclick="sketchup.cmd_pdf()">PDF</button>
        <button class="btn" id="btn-front"  onclick="sketchup.cmd_front()">Front</button>
        <button class="btn" id="btn-back"   onclick="sketchup.cmd_back()">Back</button>
        <button class="btn" id="btn-2d"     onclick="sketchup.cmd_2d()">2D:Off</button>
        <button class="btn" id="btn-colour" onclick="handleColour(event)" title="Colour picker (Shift+click to reapply last colour)">
          Colour<span class="swatch" id="colour-swatch"></span>
        </button>
        <button class="btn" id="btn-thick" onclick="handleThick(event)" title="Line thickness (Shift+click to reapply last thickness)">
          Thick<span class="lwbar" id="thick-bar"></span>
        </button>
        <button class="btn" id="btn-sec" onclick="sketchup.cmd_sec()" title="Section markers, grid generator and level markers">Section</button>
        <button class="btn" id="btn-pal" onclick="sketchup.cmd_pal()" title="Drag and drop palette (personal shape library)">Palette</button>
        <button class="btn" id="btn-snap" onclick="sketchup.cmd_snap()" title="Save selection as high-quality snapshot (.skp + .svg)">Snap+</button>
        <button class="btn" id="btn-snpl" onclick="sketchup.cmd_snap_load()" title="Load a saved snapshot into this drawing">Snap-</button>
        <button class="btn" id="btn-style" onclick="sketchup.cmd_line_style()" title="Change selected lines to any of the 12 broken-line styles (Dash, Chain-dot, etc.)">Style</button>
        <button class="btn" id="btn-hatch" onclick="sketchup.cmd_hatch()" title="Fill selected face(s) with a drafting pattern (concrete, diagonal, cross-hatch, brick, earth)">Hatch</button>
      </div>
      <script>
      function set2DState(on) {
        var b = document.getElementById('btn-2d');
        b.textContent = on ? '2D:On' : '2D:Off';
        if (on) { b.classList.add('on'); } else { b.classList.remove('on'); }
      }
      function setLastColour(hex) {
        var s = document.getElementById('colour-swatch');
        if (s) s.style.background = hex;
      }
      function handleColour(e) {
        if (e.shiftKey) {
          sketchup.cmd_colour_last();
        } else {
          sketchup.cmd_colour();
        }
      }
      function setLastThickness(mm) {
        var b = document.getElementById('thick-bar');
        if (!b) return;
        var px = Math.max(1, Math.round(mm * 3.78));
        if (px > 8) px = 8;
        b.style.height = px + 'px';
      }
      function handleThick(e) {
        if (e.shiftKey) {
          sketchup.cmd_thick_last();
        } else {
          sketchup.cmd_thick();
        }
      }
      </script>
      </body>
      </html>
    HTML

    def self.build
      @dialog = UI::HtmlDialog.new(
        dialog_title: "SketchDraw #{SketchDraw::PLUGIN_VER}",
        scrollable:   false,
        resizable:    false,
        width:        442,
        height:       185,
        min_width:    442,
        min_height:   185,
        style:        UI::HtmlDialog::STYLE_UTILITY
      )

      @dialog.set_html(TOOLBAR_HTML)

      @dialog.add_action_callback('cmd_paper') { |_| PaperFrame.show_dialog }
      @dialog.add_action_callback('cmd_tmpl')  { |_| PaperFrame.load_template }
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
      @dialog.add_action_callback('cmd_colour') do |_|
        ColourPicker.pick_and_apply
        refresh_colour_swatch
      end
      @dialog.add_action_callback('cmd_colour_last') do |_|
        ColourPicker.apply_last
        refresh_colour_swatch
      end
      @dialog.add_action_callback('cmd_thick') do |_|
        LineThickness.pick_and_apply
        refresh_thickness_bar
      end
      @dialog.add_action_callback('cmd_thick_last') do |_|
        LineThickness.apply_last
        refresh_thickness_bar
      end
      @dialog.add_action_callback('cmd_sec') { |_| SectionGrid.open_dialog }
      @dialog.add_action_callback('cmd_pal') { |_| Palette.open_panel }
      @dialog.add_action_callback('cmd_snap')      { |_| Snapshot.save }
      @dialog.add_action_callback('cmd_snap_load') { |_| Snapshot.load }
      @dialog.add_action_callback('cmd_line_style') { |_| LineStyle.activate }
      @dialog.add_action_callback('cmd_hatch')      { |_| Hatch.activate }

      @dialog.show
      refresh_colour_swatch
      refresh_thickness_bar
    end

    # Push the current last-used colour to the toolbar swatch element
    def self.refresh_colour_swatch
      return unless @dialog && @dialog.visible?
      c   = ColourPicker.last_colour
      hex = format("'#%02X%02X%02X'", c.red, c.green, c.blue)
      @dialog.execute_script("setLastColour(#{hex})")
    rescue
      nil
    end

    # Push the current last-used line thickness to the toolbar bar element
    def self.refresh_thickness_bar
      return unless @dialog && @dialog.visible?
      mm = LineThickness.last_mm
      @dialog.execute_script("setLastThickness(#{mm})")
    rescue
      nil
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
