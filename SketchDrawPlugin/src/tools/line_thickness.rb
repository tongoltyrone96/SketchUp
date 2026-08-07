module SketchDraw
  module LineThickness
    ATTR_NS  = SketchDraw::PLUGIN_ID
    ATTR_KEY = 'line_width_mm'.freeze

    # v5.76: re-tuned to remain visually distinct from the PDF default
    # (1.2pt ≈ 0.42mm). Previous ISO 128-20 values (0.13/0.25/0.5/0.7/1.0)
    # made "Thin" invisible under the old thin default; against the new
    # thicker default they'd be indistinguishable too. New scale keeps
    # ISO-ish spacing but shifted up so Medium+ reads as clearly heavier.
    LEVELS = [
      { name: 'Extra Thin',  mm: 0.20 },   # 0.57pt — thinner than default
      { name: 'Thin',        mm: 0.35 },   # 1.0pt  — subtle, near default
      { name: 'Medium',      mm: 0.60 },   # 1.7pt  — clearly heavier
      { name: 'Thick',       mm: 0.90 },   # 2.55pt — obviously heavier
      { name: 'Extra Thick', mm: 1.20 }    # 3.4pt  — very bold
    ].freeze

    # Dialog's initial value when the selection has no stored thickness.
    # Matches the new Medium — the most common pick for structural members.
    DEFAULT_MM = 0.60

    # Session-persistent last-used thickness (mm) — used only by the Shift+click
    # "apply last" shortcut, NOT as the dialog's initial value.
    @last_mm = DEFAULT_MM

    def self.last_mm
      @last_mm
    end

    # ── Entry points ────────────────────────────────────────────────────
    def self.pick_and_apply
      return unless SketchDraw.version_ok?
      sel = Sketchup.active_model.selection
      edges = sel.grep(Sketchup::Edge)
      if edges.empty?
        UI.messagebox('Select one or more lines first, then click Thick.')
        return
      end
      show_dialog(edges)
    end

    def self.apply_last
      return unless SketchDraw.version_ok?
      sel = Sketchup.active_model.selection
      edges = sel.grep(Sketchup::Edge)
      if edges.empty?
        UI.messagebox('Select one or more lines first.')
        return
      end
      apply_thickness(edges, @last_mm)
    end

    # ── Core apply logic ────────────────────────────────────────────────
    # Stores the thickness in mm as an attribute on each edge. The PDF
    # exporter reads this attribute and emits the correct stroke width.
    # The value is clamped to a reasonable range (0.05 - 3.0 mm).
    #
    # A dedicated ThicknessOverlay renders the width in the viewport too,
    # so users see the change immediately. That overlay only ever caches
    # edges that carry the attribute — for the typical ≤50-edge selection
    # both the invalidation walk and per-frame redraw are sub-millisecond
    # even on huge scaffolds.
    def self.apply_thickness(edges, mm)
      mm = mm.to_f.clamp(0.05, 3.0)
      model = Sketchup.active_model
      layer0 = model.layers[0]  # 'Layer0' / 'Untagged' — used to un-tag styled edges
      SketchDraw::Debug.log('Apply', "apply_thickness begin: edges=#{edges.length} mm=#{mm}")
      untagged_count = 0
      model.start_operation('Set Line Thickness', true)
      begin
        edges.each do |e|
          next unless e.is_a?(Sketchup::Edge)
          e.set_attribute(ATTR_NS, ATTR_KEY, mm.round(3))
          # If this edge is currently on a plugin-created Style tag
          # (SKD_Style_XXX), MOVE IT OFF. Reason: an edge with both a
          # thickness attribute AND a native-SU-rendered dash pattern
          # gets drawn TWICE — once thin by SU (from the tag's
          # line_style), once thick by our overlay (from the pattern
          # attribute). SU's internal dash cadence and our pattern
          # cadence can NEVER match perfectly (SU is view-resolution
          # based, ours is pixel-fixed), so the two dashes drift out
          # of phase and the edge looks "broken". Un-tagging leaves
          # SU to render a solid stroke; our overlay is the sole dash
          # renderer, so the pattern stays perfectly consistent.
          # The line_style_name attribute stays on the edge — PDF
          # export reads it directly, so PDF output is unchanged.
          begin
            lay = e.layer
            if lay && lay.name.to_s.start_with?('SKD_Style_') && layer0
              e.layer = layer0
              untagged_count += 1
            end
          rescue
          end
        end
        SketchDraw::Debug.log('Apply', "un-tagged #{untagged_count} edges from SKD_Style_")
        # Model-level flag so ThicknessOverlayManager.install_if_needed can
        # decide in O(1) on future model opens whether to re-attach the overlay.
        model.set_attribute(ATTR_NS, 'has_line_thickness', true)
        model.commit_operation
        @last_mm = mm
        # Surgical cache update on the thickness overlay only — colour
        # display is now handled entirely by SketchUp's native rendering
        # (EdgeColorMode=1), so no ColourOverlay to touch.
        xf = Geom::Transformation.new
        touched_pairs = edges.select { |e| e.is_a?(Sketchup::Edge) }
                             .map    { |e| { edge: e, xform: xf } }
        SketchDraw::ThicknessOverlayManager.install(model)               rescue nil
        SketchDraw::ThicknessOverlayManager.refresh_edges(touched_pairs) rescue nil
        SketchDraw::Debug.log('Apply', "scheduling deferred refresh (timer chain 0s/0.05s/0.15s)")
        # Multi-attempt refresh chain. Some SU 2026 builds ignore a single
        # post-callback refresh (dialog still tearing down), so we fire
        # three: immediate, +50ms, +150ms. Each does invalidate + refresh
        # + a camera-nudge (setting camera to its current position is the
        # documented SU trick to force the render pipeline — including
        # overlays — to run a full pass). Cheap enough (three no-op-if-
        # already-drawn passes) but robust against timing races.
        [0.0, 0.05, 0.15].each do |delay|
          UI.start_timer(delay, false) do
            m = Sketchup.active_model
            v = m && m.active_view
            next unless v
            begin
              cam = v.camera
              cam.set(cam.eye, cam.target, cam.up)  # camera-nudge
            rescue
            end
            v.invalidate rescue nil
            v.refresh    rescue nil
            SketchDraw::Debug.log('Timer', "refresh fired (delay=#{delay}s)")
          end
        end
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("Thickness apply failed: #{e.message}")
      end
    end

    # Returns the thickness (mm) stored on an edge, or nil if none.
    def self.edge_thickness_mm(edge)
      v = edge.get_attribute(ATTR_NS, ATTR_KEY)
      v && v.to_f > 0 ? v.to_f : nil
    rescue
      nil
    end

    # If every edge in the selection has the same stored thickness, return it —
    # so re-opening the dialog on a new selection reflects that selection's
    # actual state, not whatever the user picked last. Returns nil for
    # mixed selections or when no edge has a stored value.
    def self.detect_initial_mm(edges)
      values = edges.map { |e| edge_thickness_mm(e) }.compact
      return nil if values.empty?
      first = values.first
      values.all? { |v| (v - first).abs < 0.001 } ? first : nil
    rescue
      nil
    end
    private_class_method :detect_initial_mm

    # ── Dialog ──────────────────────────────────────────────────────────
    def self.show_dialog(edges)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Line Thickness',
        preferences_key: 'SketchDraw_Thickness_v1',
        width:  340,
        height: 420,
        style:  UI::HtmlDialog::STYLE_DIALOG
      )

      # Dialog initial value reflects the selection's actual state, not what
      # the user picked previously on another edge:
      #   • all selected edges share the same stored mm → that value
      #   • mixed or none stored → DEFAULT_MM (0.50 Medium)
      initial_mm  = detect_initial_mm(edges) || DEFAULT_MM
      last_str    = format('%.2f', initial_mm)
      levels_json = LEVELS.map { |lv|
        %({name:"#{lv[:name]}", mm:#{lv[:mm]}})
      }.join(',')

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
            padding: 16px;
          }
          .preview {
            width: 100%; height: 60px;
            background: #FFFFFF;
            border: 1px solid #555;
            border-radius: 4px;
            margin-bottom: 14px;
            display: flex; align-items: center; justify-content: center;
          }
          .preview .sample {
            width: 80%; background: #000;
            height: 4px;
          }
          .levels { display: grid; grid-template-columns: 1fr; gap: 5px; }
          .lv {
            display: flex; align-items: center; gap: 12px;
            padding: 8px 12px;
            background: #3a3a3a;
            border: 1px solid #555;
            border-radius: 3px;
            cursor: pointer;
            transition: background .1s;
          }
          .lv:hover { background: #4a4a4a; }
          .lv.active { background: #0078D4; border-color: #4aa3e6; }
          .lv .swatch {
            width: 90px; height: 24px;
            background: #FFFFFF;
            border: 1px solid #666;
            display: flex; align-items: center; justify-content: center;
          }
          .lv .swatch .bar { width: 100%; background: #000; }
          .lv .txt { flex: 1; font-size: 13px; font-weight: bold; }
          .lv .mm  { font-size: 12px; color: #aaa; }
          .custom-row {
            margin-top: 12px;
            display: flex; align-items: center; gap: 8px;
          }
          .custom-row label { font-size: 12px; color: #aaa; }
          .custom-row input {
            flex: 1;
            padding: 6px 10px;
            background: #1e1e1e;
            color: #fff;
            border: 1px solid #555;
            border-radius: 3px;
            font-size: 13px;
          }
          .footer {
            flex-shrink: 0;
            display: flex; justify-content: flex-end; gap: 8px;
            padding: 12px 16px;
            border-top: 1px solid #444;
            background: #232323;
          }
          button {
            padding: 8px 22px;
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
            <div class="preview"><div class="sample" id="preview-sample"></div></div>

            <div class="levels" id="levels"></div>

            <div class="custom-row">
              <label>Custom (mm):</label>
              <input type="number" id="custom" step="0.05" min="0.05" max="3.0" value="#{last_str}">
            </div>
          </div>

          <div class="footer">
            <button class="cancel" onclick="sketchup.cancel()">Cancel</button>
            <button onclick="apply()">Apply</button>
          </div>

        <script>
          var LEVELS = [#{levels_json}];
          var chosen_mm = #{initial_mm};

          function render() {
            var box = document.getElementById('levels');
            box.innerHTML = '';
            LEVELS.forEach(function(lv) {
              var el = document.createElement('div');
              el.className = 'lv' + (Math.abs(lv.mm - chosen_mm) < 0.001 ? ' active' : '');
              // pixel width for visual preview (~3.78 px per mm at 96 DPI)
              var px = Math.max(1, Math.round(lv.mm * 3.78));
              el.innerHTML =
                '<div class="swatch"><div class="bar" style="height:' + px + 'px"></div></div>' +
                '<div class="txt">' + lv.name + '</div>' +
                '<div class="mm">' + lv.mm.toFixed(2) + ' mm</div>';
              el.onclick = function() {
                chosen_mm = lv.mm;
                document.getElementById('custom').value = lv.mm.toFixed(2);
                render();
                updatePreview();
              };
              box.appendChild(el);
            });
          }

          function updatePreview() {
            var px = Math.max(1, Math.round(chosen_mm * 3.78));
            document.getElementById('preview-sample').style.height = px + 'px';
          }

          document.getElementById('custom').addEventListener('input', function(e) {
            var v = parseFloat(e.target.value);
            if (!isNaN(v) && v > 0) {
              chosen_mm = v;
              render();
              updatePreview();
            }
          });

          function apply() {
            var v = parseFloat(document.getElementById('custom').value);
            if (isNaN(v) || v <= 0) v = chosen_mm;
            sketchup.apply_thickness(v);
          }

          render();
          updatePreview();
        </script>
        </body>
        </html>
      HTML

      dlg.set_html(html)

      dlg.add_action_callback('apply_thickness') do |_ctx, mm|
        apply_thickness(edges, mm.to_f)
        dlg.close
      end
      dlg.add_action_callback('cancel') { dlg.close }

      dlg.show
    end
    private_class_method :show_dialog
  end
end
