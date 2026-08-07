module SketchDraw
  module ColourPicker
    ATTR_NS = SketchDraw::PLUGIN_ID

    @last_colour = Sketchup::Color.new(200, 30, 30)

    def self.last_colour
      @last_colour
    end

    # ── Entry points ────────────────────────────────────────────────────
    def self.pick_and_apply
      return unless SketchDraw.version_ok?
      sel = Sketchup.active_model.selection
      if sel.empty?
        UI.messagebox('Select one or more items first, then click Colour.')
        return
      end
      show_dialog(sel.to_a)
    end

    def self.apply_last
      return unless SketchDraw.version_ok?
      sel = Sketchup.active_model.selection
      if sel.empty?
        UI.messagebox('Select one or more items first.')
        return
      end
      apply_colour(sel.to_a, @last_colour)
    end

    # ── Core apply logic ────────────────────────────────────────────────
    # Assigns a material to every supported entity. For Groups/Components
    # we also recurse into child geometry so a previously-coloured child
    # doesn't keep its old colour under the new container material.
    #
    # NOTE: In SketchUp's viewport, standalone edges (loose lines not
    # bordering a face) do NOT render material colour — this is a
    # SketchUp rendering-pipeline limitation, not a plugin bug. The
    # colour IS persisted on the edge and is emitted correctly by the
    # PDF exporter, so the final printed drawing shows the right colour.
    def self.apply_colour(entities, color)
      model = Sketchup.active_model
      model.start_operation('Apply Colour', true)
      begin
        mat = get_or_make_material(model, color)
        touched_pairs = paint_recursive(entities, mat)

        # DELIBERATELY DO NOT touch model.rendering_options or model.styles.
        # Previous versions forced EdgeColorMode=1 and DisplayColorByLayer=false
        # here "so material colours would show". Those are GLOBAL viewport
        # settings — flipping them changes how *every* edge in the drawing
        # is rendered. On D's scaffold, edges were being coloured via SketchUp
        # Layers (Tags): DisplayColorByLayer=true made all tubes / beams /
        # boards show their layer colour. Setting it to false wiped every
        # existing colour except the one we just painted. That's the "다른
        # 부분들이 검은색으로 변한다" bug.
        #
        # LineThickness works correctly precisely because it only writes
        # per-edge attributes and never touches global render state. We do
        # the same here: paint the material on the selected edges, and
        # leave the user's viewport style alone.

        model.commit_operation
        @last_colour = color

        # If any of the touched edges also carry a line_width_mm attribute,
        # ThicknessOverlay has them cached with their pre-paint colour —
        # nudge it to pick up the new material colour on the next frame.
        SketchDraw::ThicknessOverlayManager.refresh_edges(touched_pairs) rescue nil

        model.selection.clear
        model.active_view.invalidate rescue nil
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("Colour apply failed: #{e.message}")
      end
    end

    # Returns an array of {edge:, xform:} pairs for every edge whose
    # material was set. The xforms are accumulated relative to the initial
    # active_entities context, matching what ColourOverlay/ThicknessOverlay
    # store in their caches — so surgical refresh_edges calls line up
    # exactly with existing cache entries and no ghost duplicates appear.
    def self.paint_recursive(entities, mat, xform = Geom::Transformation.new)
      touched = []
      entities.each do |ent|
        case ent
        when Sketchup::Edge
          ent.material = mat
          touched << { edge: ent, xform: xform }
        when Sketchup::Face
          ent.material      = mat
          ent.back_material = mat
        when Sketchup::Group
          ent.material = mat
          touched.concat(paint_recursive(ent.entities.to_a, mat, xform * ent.transformation))
        when Sketchup::ComponentInstance
          ent.material = mat
          touched.concat(paint_recursive(ent.definition.entities.to_a, mat, xform * ent.transformation))
        end
      end
      touched
    end

    # If every selected entity has the same material colour, return that
    # colour so the dialog opens with it selected. Mixed or empty → nil.
    def self.detect_initial_colour(entities)
      colors = entities.map { |e| e.material rescue nil }
                       .compact
                       .map    { |m| m.respond_to?(:color) ? m.color : nil }
                       .compact
      return nil if colors.empty?
      first = colors.first
      same = colors.all? do |c|
        c.red == first.red && c.green == first.green && c.blue == first.blue
      end
      same ? first : nil
    rescue
      nil
    end

    def self.get_or_make_material(model, color)
      name = format('SKD_col_%02X%02X%02X', color.red, color.green, color.blue)
      mat  = model.materials[name]
      unless mat
        mat = model.materials.add(name)
        mat.color = color
      end
      mat
    end

    # ── Dialog ──────────────────────────────────────────────────────────
    def self.show_dialog(entities)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Pick Colour',
        preferences_key: 'SketchDraw_Colour_v1',
        width:  340,
        height: 250,
        style:  UI::HtmlDialog::STYLE_DIALOG
      )

      # Reflect the selection's current colour in the dialog instead of the
      # last-used one: if every selected entity shares the same material
      # colour, use it; otherwise fall back to @last_colour.
      initial_colour = detect_initial_colour(entities) || @last_colour
      last_hex = format('#%02X%02X%02X',
                        initial_colour.red, initial_colour.green, initial_colour.blue)

      html = <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          html, body { height: 100%; }
          body {
            font-family: Arial, sans-serif;
            background: #2b2b2b;
            color: #ddd;
            display: flex;
            flex-direction: column;
            overflow: hidden;
          }
          .content {
            flex: 1;
            overflow-y: auto;
            padding: 10px 12px;
          }
          .preview {
            width: 100%; height: 40px;
            border: 1px solid #555;
            border-radius: 3px;
            margin-bottom: 8px;
          }
          input[type=color] {
            width: 100%; height: 36px;
            border: 1px solid #555;
            border-radius: 3px;
            background: #1e1e1e;
            cursor: pointer;
          }
          .label {
            font-size: 11px; color: #aaa; margin: 8px 0 4px;
          }
          .swatches {
            display: grid;
            grid-template-columns: repeat(6, 1fr);
            gap: 4px;
          }
          .swatch {
            height: 26px;
            border: 1px solid #555;
            border-radius: 3px;
            cursor: pointer;
            transition: transform .08s;
          }
          .swatch:hover { border-color: #fff; transform: scale(1.06); }
          .note {
            margin-top: 10px;
            padding: 8px 10px;
            background: #333;
            border-left: 3px solid #F9A825;
            font-size: 11px;
            color: #ccc;
            line-height: 1.4;
          }
          .footer {
            flex-shrink: 0;
            display: flex; justify-content: flex-end; gap: 8px;
            padding: 8px 12px;
            border-top: 1px solid #444;
            background: #232323;
          }
          button {
            padding: 6px 18px;
            background: #0078D4; color: #fff;
            border: none; border-radius: 3px;
            font-size: 12px; font-weight: bold;
            cursor: pointer;
          }
          button.cancel { background: #505050; }
          button:hover { filter: brightness(1.15); }
        </style>
        </head>
        <body>
          <div class="content">
            <div class="preview" id="preview" style="background:#{last_hex};"></div>

            <input type="color" id="picker" value="#{last_hex}" oninput="updatePreview()">

            <div class="label">Common colours</div>
            <div class="swatches">
              <div class="swatch" style="background:#000000" onclick="pickSwatch('#000000')"></div>
              <div class="swatch" style="background:#FFFFFF" onclick="pickSwatch('#FFFFFF')"></div>
              <div class="swatch" style="background:#808080" onclick="pickSwatch('#808080')"></div>
              <div class="swatch" style="background:#C62828" onclick="pickSwatch('#C62828')"></div>
              <div class="swatch" style="background:#2E7D32" onclick="pickSwatch('#2E7D32')"></div>
              <div class="swatch" style="background:#1565C0" onclick="pickSwatch('#1565C0')"></div>
              <div class="swatch" style="background:#F9A825" onclick="pickSwatch('#F9A825')"></div>
              <div class="swatch" style="background:#E65100" onclick="pickSwatch('#E65100')"></div>
              <div class="swatch" style="background:#6A1B9A" onclick="pickSwatch('#6A1B9A')"></div>
              <div class="swatch" style="background:#00838F" onclick="pickSwatch('#00838F')"></div>
              <div class="swatch" style="background:#8B4513" onclick="pickSwatch('#8B4513')"></div>
              <div class="swatch" style="background:#4CAF50" onclick="pickSwatch('#4CAF50')"></div>
            </div>

          </div>

          <div class="footer">
            <button class="cancel" onclick="sketchup.cancel()">Cancel</button>
            <button onclick="apply()">Apply</button>
          </div>

        <script>
          function updatePreview() {
            document.getElementById('preview').style.background =
              document.getElementById('picker').value;
          }
          function pickSwatch(hex) {
            document.getElementById('picker').value = hex;
            updatePreview();
          }
          function apply() {
            sketchup.apply_colour(document.getElementById('picker').value);
          }
        </script>
        </body>
        </html>
      HTML

      dlg.set_html(html)

      dlg.add_action_callback('apply_colour') do |_ctx, hex|
        color = hex_to_color(hex)
        apply_colour(entities, color) if color
        dlg.close
      end

      dlg.add_action_callback('cancel') { dlg.close }

      dlg.show
    end

    def self.hex_to_color(hex)
      s = hex.to_s.sub('#', '')
      return nil unless s.length == 6
      r = s[0, 2].to_i(16)
      g = s[2, 2].to_i(16)
      b = s[4, 2].to_i(16)
      Sketchup::Color.new(r, g, b)
    rescue
      nil
    end
  end
end
