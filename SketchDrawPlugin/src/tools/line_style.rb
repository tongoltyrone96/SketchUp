module SketchDraw
  # Feature: convert selected edges to any of the 12 ISO 128-20 broken-line
  # styles. Uses SketchUp's native line_style API (available in SketchUp
  # 2019+), which the PDF exporter already reads — so no changes needed on
  # the export side.
  #
  # Zero ongoing performance cost — no observers, no per-frame code, nothing
  # runs unless the user actively clicks the toolbar button.
  module LineStyle
    ATTR_NS = SketchDraw::PLUGIN_ID

    # ISO 128-20 line styles matching SketchUp's built-in names. The SVG
    # dash pattern is used for the dialog preview only.
    STYLES = [
      { id: 'Solid Basic',            name: 'Solid',                  dash: '' },
      { id: 'Short dash',             name: 'Short dash',             dash: '4,2' },
      { id: 'Dash',                   name: 'Dash',                   dash: '8,3' },
      { id: 'Dot',                    name: 'Dot',                    dash: '1,3' },
      { id: 'Dash dot',               name: 'Dash-dot (chain)',       dash: '10,3,1,3' },
      { id: 'Dash double-dot',        name: 'Dash-double-dot',        dash: '10,3,1,3,1,3' },
      { id: 'Dash triple-dot',        name: 'Dash-triple-dot',        dash: '10,3,1,3,1,3,1,3' },
      { id: 'Double-dash dot',        name: 'Double-dash-dot',        dash: '10,3,10,3,1,3' },
      { id: 'Double-dash double-dot', name: 'Double-dash-double-dot', dash: '10,3,10,3,1,3,1,3' },
      { id: 'Double-dash triple-dot', name: 'Double-dash-triple-dot', dash: '10,3,10,3,1,3,1,3,1,3' },
      { id: 'Long-dash dash',         name: 'Long-dash dash',         dash: '15,3,5,3' },
      { id: 'Long-dash double-dash',  name: 'Long-dash double-dash',  dash: '15,3,5,3,5,3' }
    ].freeze

    # ── Entry point ─────────────────────────────────────────────────────
    def self.activate
      return unless SketchDraw.version_ok?
      sel   = Sketchup.active_model.selection
      edges = sel.grep(Sketchup::Edge)
      if edges.empty?
        UI.messagebox('Select one or more lines first, then click Style.')
        return
      end
      show_dialog(edges)
    end

    # ── Core apply logic ────────────────────────────────────────────────
    # SketchUp's Edge class does NOT have a `line_style=` setter — line
    # styles live on Layers (Tags). So we create/reuse a dedicated tag per
    # style, set the tag's line_style, and move the selected edges onto
    # that tag. That gives correct dashed rendering in the viewport.
    # We also stash the style name as an attribute on each edge so the PDF
    # exporter can pick it up directly even if the tag later gets deleted.
    def self.apply_style(edges, style_id)
      model = Sketchup.active_model
      unless model.respond_to?(:line_styles)
        UI.messagebox('SketchUp line styles require SketchUp 2019 or newer.')
        return
      end

      style = model.line_styles[style_id] rescue nil
      unless style
        UI.messagebox("Line style '#{style_id}' is not available in this SketchUp version.")
        return
      end

      # Create / reuse a tag whose line style matches the chosen preset.
      layer_name = "SKD_Style_#{style_id.gsub(/[^A-Za-z0-9]+/, '_')}"
      layer      = nil
      begin
        layer = model.layers[layer_name] || model.layers.add(layer_name)
        layer.line_style = style if layer.respond_to?(:line_style=)
      rescue => e
        # If tag/line_style API isn't usable, fall through — the edge
        # attribute below still lets PDF export render the correct style.
        puts "[SketchDraw::LineStyle] layer setup failed: #{e.message}"
        layer = nil
      end

      model.start_operation('Set Line Style', true)
      begin
        edges.each do |e|
          next unless e.is_a?(Sketchup::Edge) && e.valid?
          # Attribute — read by PDF export (works even if tag is gone).
          e.set_attribute(ATTR_NS, 'line_style_name', style_id)
          # Tag — makes the viewport render the dashed pattern natively.
          # BUT skip the tag move if this edge already has a thickness
          # attribute. Reason: for a thick edge, our ThicknessOverlay
          # is going to draw thick dashes with its own (pixel-fixed)
          # cadence, and SU's native tag-driven dash rendering uses a
          # different (view-resolution) cadence. Both fire on the same
          # edge → two dash patterns drift out of phase → visual mess.
          # Un-tagged thick edges get rendered as solid strokes by SU
          # (invisible under our thick overlay anyway), while the
          # overlay is the sole dash renderer. Perfect consistency.
          # Non-thick edges still get the tag → SU natively renders
          # the dash pattern, zero overlay cost.
          if layer && e.respond_to?(:layer=)
            has_thickness = false
            begin
              v = e.get_attribute(SketchDraw::LineThickness::ATTR_NS,
                                  SketchDraw::LineThickness::ATTR_KEY)
              has_thickness = v && v.to_f > 0
            rescue
            end
            e.layer = layer unless has_thickness
          end
        end
        model.commit_operation
        # Surgical overlay refresh — pattern_for() will now pick up the
        # new line_style_name and draw thick dashes for thick edges.
        xf = Geom::Transformation.new
        pairs = edges.select { |e| e.is_a?(Sketchup::Edge) && e.valid? }
                     .map    { |e| { edge: e, xform: xf } }
        SketchDraw::ThicknessOverlayManager.refresh_edges(pairs) rescue nil
        SketchDraw::Debug.log('Style', "apply_style: #{edges.length} edges, style=#{style_id}, scheduling refresh chain")
        # Same multi-attempt refresh chain as line_thickness. See there
        # for the full rationale (camera-nudge + retries at 0/50/150 ms).
        [0.0, 0.05, 0.15].each do |delay|
          UI.start_timer(delay, false) do
            m = Sketchup.active_model
            v = m && m.active_view
            next unless v
            begin
              cam = v.camera
              cam.set(cam.eye, cam.target, cam.up)
            rescue
            end
            v.invalidate rescue nil
            v.refresh    rescue nil
            SketchDraw::Debug.log('Timer', "style refresh fired (delay=#{delay}s)")
          end
        end
      rescue => err
        model.abort_operation rescue nil
        UI.messagebox("Line style apply failed: #{err.message}")
      end
    end

    # ── Dialog ──────────────────────────────────────────────────────────
    def self.show_dialog(edges)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Line Style',
        preferences_key: 'SketchDraw_LineStyle_v1',
        width:  380,
        height: 500,
        style:  UI::HtmlDialog::STYLE_DIALOG
      )

      # Detect current style of first edge for default selection.
      first_edge = edges.first
      current_id = 'Solid Basic'
      begin
        ls = first_edge.line_style
        current_id = ls.name if ls && ls.respond_to?(:name)
      rescue
      end

      styles_json = STYLES.map { |s|
        %({id:"#{s[:id]}", name:"#{s[:name]}", dash:"#{s[:dash]}"})
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
            display: flex; flex-direction: column;
            overflow: hidden;
          }
          .content {
            flex: 1;
            overflow-y: auto;
            padding: 10px 12px;
          }
          .styles { display: flex; flex-direction: column; gap: 4px; }
          .lv {
            display: flex; align-items: center; gap: 12px;
            padding: 7px 10px;
            background: #3a3a3a;
            border: 1px solid #555;
            border-radius: 3px;
            cursor: pointer;
            transition: background .1s;
          }
          .lv:hover { background: #4a4a4a; }
          .lv.active { background: #0078D4; border-color: #4aa3e6; }
          .lv .preview {
            width: 150px; height: 18px;
            background: #fff;
            border: 1px solid #666;
            display: flex; align-items: center; justify-content: center;
            flex-shrink: 0;
          }
          .lv .preview svg { width: 140px; height: 5px; overflow: visible; }
          .lv .name { flex: 1; font-size: 12px; font-weight: bold; }
          .footer {
            flex-shrink: 0;
            display: flex; justify-content: flex-end; gap: 8px;
            padding: 10px 12px;
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
            <div class="styles" id="styles"></div>
          </div>
          <div class="footer">
            <button class="cancel" onclick="sketchup.cancel()">Cancel</button>
            <button onclick="apply()">Apply</button>
          </div>
        <script>
          var STYLES = [#{styles_json}];
          var chosen = "#{current_id}";

          function render() {
            var box = document.getElementById('styles');
            box.innerHTML = '';
            STYLES.forEach(function(s) {
              var el = document.createElement('div');
              el.className = 'lv' + (s.id === chosen ? ' active' : '');
              var dashAttr = s.dash === '' ? '' : ' stroke-dasharray="' + s.dash + '"';
              el.innerHTML =
                '<div class="preview"><svg viewBox="0 0 140 5" preserveAspectRatio="none">' +
                '<line x1="0" y1="2.5" x2="140" y2="2.5" stroke="black" stroke-width="1.5"' + dashAttr + '/>' +
                '</svg></div>' +
                '<div class="name">' + s.name + '</div>';
              el.onclick = function() { chosen = s.id; render(); };
              box.appendChild(el);
            });
          }

          function apply() { sketchup.apply_style(chosen); }
          render();
        </script>
        </body>
        </html>
      HTML

      dlg.set_html(html)

      dlg.add_action_callback('apply_style') do |_ctx, style_id|
        apply_style(edges, style_id)
        dlg.close
      end

      dlg.add_action_callback('cancel') { dlg.close }

      dlg.show
    end
  end
end
