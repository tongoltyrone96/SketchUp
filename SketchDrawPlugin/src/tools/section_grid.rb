module SketchDraw
  # ============================================================================
  # Feature E - Section Markers, Grid Generator, and Level Markers
  # ============================================================================
  # A library of construction drawing annotations that can be inserted from the
  # SketchDraw toolbar. Contains three sub-tools accessed from a single dialog:
  #   1. Section Markers (arrows + circle/diamond labels, solid or broken)
  #   2. Grid Generator  (full column/row grid, regular or irregular spacing)
  #   3. Level Markers   (FFL, SSL, DATUM, Top of Parapet)
  #
  # All geometry is created on the Z=0 plane and grouped for easy manipulation.
  # Marker sizes are in paper millimetres.
  # ============================================================================
  module SectionGrid
    ATTR_NS = SketchDraw::PLUGIN_ID

    # ── Marker size constants (paper mm) ────────────────────────────────
    CIRCLE_R      = 5.0     # circle/diamond label radius
    ARROW_LEN     = 15.0    # arrow shaft length
    ARROW_HEAD    = 4.0     # arrow head half-width
    TEXT_HEIGHT   = 3.5     # label text height
    LINE_WEIGHT_ATTR = 'line_width_mm'.freeze
    CHAIN_DASH_MM = 8.0
    CHAIN_GAP_MM  = 2.0
    CHAIN_DOT_MM  = 0.5

    # Number of dots between dashes in the chain-dot line pattern (1..3).
    # Set transiently via with_dot_count so Sections/Grid callers can pick
    # a different value without polluting each other's builds.
    @chain_dot_count = 1

    def self.chain_dot_count
      @chain_dot_count || 1
    end

    def self.with_dot_count(n)
      prev = @chain_dot_count
      @chain_dot_count = n.to_i.clamp(1, 3)
      yield
    ensure
      @chain_dot_count = prev
    end

    # Size multiplier applied to paper-mm sizes at geometry-generation time.
    # Same idea as TextTool / ArrowTool: instead of relying on a live group
    # transformation to scale the marker (which caused SU to drop face and
    # add_3d_text rendering inside the scaled group), each build_* helper
    # multiplies its .mm values by this so the local geometry is already at
    # the visible size. build() sets it via with_size_mult from
    # SketchDraw::State.paper_scale_multiplier_at; it's 1.0 inside a paper
    # frame (paper output unchanged).
    @size_mult = 1.0

    def self.size_mult
      @size_mult || 1.0
    end

    def self.with_size_mult(mult)
      prev = @size_mult
      m = mult.to_f
      @size_mult = (m > 0) ? m : 1.0
      yield
    ensure
      @size_mult = prev
    end


    # ── Entry point ─────────────────────────────────────────────────────
    def self.open_dialog
      return unless SketchDraw.version_ok?
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Section, Grid & Level',
        preferences_key: 'SketchDraw_SectionGrid_v1',
        width:  460,
        height: 520,
        style:  UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_html(dialog_html)

      dlg.add_action_callback('place_section') do |_ctx, style, label, broken, label2 = nil, dot_count = 1|
        dlg.close
        Sections.start_placement(
          style, label, broken == 'true' || broken == true, label2 || label, dot_count.to_i
        )
      end

      dlg.add_action_callback('place_grid') do |_ctx, cfg_json|
        dlg.close
        Grid.start_placement(cfg_json)
      end

      dlg.add_action_callback('place_level') do |_ctx, style, elev|
        dlg.close
        Levels.start_placement(style, elev)
      end

      dlg.add_action_callback('cancel') { dlg.close }
      dlg.show
    end

    # ── Dialog HTML (tabs) ──────────────────────────────────────────────
    def self.dialog_html
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          html, body { height: 100%; }
          body {
            font-family: Arial, sans-serif;
            background: #2b2b2b; color: #ddd;
            display: flex; flex-direction: column;
            overflow: hidden;
          }
          .tabs { display: flex; border-bottom: 2px solid #444; flex-shrink: 0; }
          .tab {
            padding: 10px 18px;
            cursor: pointer;
            font-size: 13px; font-weight: bold;
            color: #aaa;
            border-right: 1px solid #444;
          }
          .tab.active { background: #3a3a3a; color: #fff; border-bottom: 2px solid #0078D4; margin-bottom: -2px; }
          .content { flex: 1; overflow-y: auto; }
          .panel { display: none; padding: 14px 16px; }
          .panel.active { display: block; }
          h3 { font-size: 13px; margin-bottom: 8px; color: #ddd; }
          .row { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
          .row label { font-size: 12px; color: #bbb; width: 140px; }
          input[type=text], input[type=number], select {
            padding: 6px 8px;
            background: #1e1e1e; color: #fff;
            border: 1px solid #555; border-radius: 3px;
            font-size: 12px;
            flex: 1;
          }
          input[type=checkbox] { margin-right: 6px; }
          .styles { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-bottom: 12px; }
          .style-card {
            padding: 8px;
            background: #3a3a3a;
            border: 1px solid #555;
            border-radius: 3px;
            cursor: pointer;
            text-align: center;
            font-size: 11px;
          }
          .style-card:hover { background: #4a4a4a; }
          .style-card.active { background: #0078D4; border-color: #4aa3e6; }
          .style-preview {
            height: 60px;
            background: #fff;
            border: 1px solid #666;
            margin-bottom: 6px;
            display: flex; align-items: center; justify-content: center;
            color: #000;
          }
          .adv-table {
            max-height: 160px; overflow-y: auto;
            border: 1px solid #555; border-radius: 3px;
            padding: 6px;
            background: #1e1e1e;
            margin-top: 6px;
          }
          .adv-table .adv-row {
            display: flex; align-items: center; gap: 6px; margin-bottom: 4px;
          }
          .adv-table .adv-row label {
            width: 70px; color: #bbb; font-size: 11px;
          }
          .footer {
            flex-shrink: 0;
            display: flex; justify-content: flex-end; gap: 8px;
            padding: 10px 16px;
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
          <div class="tabs">
            <div class="tab active" onclick="showTab('sec')">Section Markers</div>
            <div class="tab" onclick="showTab('grid')">Grid Generator</div>
            <div class="tab" onclick="showTab('lvl')">Level Markers</div>
          </div>

          <div class="content">
            <!-- SECTION MARKERS TAB -->
            <div class="panel active" id="panel-sec">
              <h3>Pick a section marker style</h3>
              <div class="styles" id="sec-styles"></div>

              <div class="row">
                <label id="sec-label1-lbl">Label (A, B, 1, 2 ...):</label>
                <input type="text" id="sec-label" value="A" maxlength="4">
              </div>
              <div class="row" id="sec-label2-row" style="display:none;">
                <label id="sec-label2-lbl">Second label (optional):</label>
                <input type="text" id="sec-label2" value="A1" maxlength="4">
              </div>
              <div class="row">
                <label style="width:auto;">
                  <input type="checkbox" id="sec-broken" onchange="toggleDotCount()"> Broken (chain-dot) line
                </label>
                <select id="sec-dotcount" style="display:none; margin-left:10px; width:110px; flex:none;">
                  <option value="1" selected>1 dot between</option>
                  <option value="2">2 dots between</option>
                  <option value="3">3 dots between</option>
                </select>
              </div>
            </div>

            <!-- GRID GENERATOR TAB -->
            <div class="panel" id="panel-grid">
              <h3>Grid generator</h3>
              <div class="row">
                <label>Columns (letters A ...):</label>
                <input type="number" id="g-cols" value="5" min="2" max="30">
              </div>
              <div class="row">
                <label>Rows (numbers 1 ...):</label>
                <input type="number" id="g-rows" value="3" min="2" max="30">
              </div>
              <div class="row">
                <label>Line style:</label>
                <select id="g-line">
                  <option value="solid">Solid</option>
                  <option value="broken" selected>Broken (chain-dot)</option>
                </select>
              </div>
              <div class="row">
                <label>Marker shape:</label>
                <select id="g-marker">
                  <option value="round" selected>Round</option>
                  <option value="diamond">Diamond</option>
                  <option value="split_v">Split circle (vertical divider)</option>
                  <option value="bracket">Bracket only (no label)</option>
                </select>
              </div>
              <div class="row">
                <label>Horizontal spacing (model mm):</label>
                <input type="number" id="g-hspace" value="2000" step="100" min="1">
              </div>
              <div class="row">
                <label>Vertical spacing (model mm):</label>
                <input type="number" id="g-vspace" value="2000" step="100" min="1">
              </div>
              <div class="row">
                <label>Label text size:</label>
                <select id="g-textsize">
                  <option value="small">Small</option>
                  <option value="medium" selected>Medium (default)</option>
                  <option value="large">Large</option>
                  <option value="xlarge">Extra Large</option>
                </select>
              </div>
              <div class="row">
                <label><input type="checkbox" id="g-adv" onchange="toggleAdvanced()"> Advanced (per-gap) spacing</label>
              </div>
              <div id="g-adv-panel" style="display:none;">
                <div style="font-size:11px; color:#aaa; margin-bottom:4px;">Column gaps (A-B, B-C ...):</div>
                <div class="adv-table" id="g-adv-cols"></div>
                <div style="font-size:11px; color:#aaa; margin: 6px 0 4px;">Row gaps (1-2, 2-3 ...):</div>
                <div class="adv-table" id="g-adv-rows"></div>
              </div>
            </div>

            <!-- LEVEL MARKERS TAB -->
            <div class="panel" id="panel-lvl">
              <h3>Pick a level marker</h3>
              <div class="styles" id="lvl-styles"></div>

              <div class="row">
                <label>Elevation value:</label>
                <input type="text" id="lvl-elev" value="+00.000M" maxlength="16">
              </div>
            </div>
          </div>

          <div class="footer">
            <button class="cancel" onclick="sketchup.cancel()">Cancel</button>
            <button id="place-btn" onclick="placeCurrent()">Place Marker</button>
          </div>

        <script>
          // ── Section marker styles ─────────────────────────────────
          var SEC_STYLES = [
            { id:'ref_aa_directional',            name:'A-A directional (letter + arrow)' },
            { id:'side_arrow_dual',               name:'Side arrow, both ends' },
            { id:'side_arrow_bracket',            name:'Side arrow top + bracket bottom' },
            { id:'ref_h_arrow_single',            name:'Ref: circle + wedges (single label)' },
            { id:'arrow_round_filled',            name:'Filled arrow, round label' },
            { id:'arrow_round_hollow',            name:'Hollow arrow, round label' },
            { id:'arrow_diamond',                 name:'Filled arrow, diamond label' },
            { id:'full_section',                  name:'Full section line (A-A)' },
            { id:'elevation_callout',             name:'Elevation callout' },
            { id:'circle_only',                   name:'Circle with letter/number' },
            { id:'section_horizontal',            name:'Horizontal section (B-B)' },
            { id:'section_bracket_round',         name:'Bracket ends, round label' },
            { id:'section_bracket_split_diamond', name:'Bracket + arrow, split diamond' },
            { id:'ref_split_h_arrow',             name:'Ref: split H circle + wedges',        split:'h' },
            { id:'ref_split_v_arrow',             name:'Ref: split V circle + down arrow',    split:'v' }
          ];
          var chosenSection = 'ref_aa_directional';

          var LVL_STYLES = [
            { id:'ffl',          name:'FFL (Finished Floor Level)' },
            { id:'ssl',          name:'SSL (Structural Slab Level)' },
            { id:'datum',        name:'DATUM' },
            { id:'parapet',      name:'Top of Parapet' },
            { id:'cross',        name:'Cross marker' },
            { id:'ffl_ssl_split', name:'FFL/SSL split circle (Ref)' }
          ];
          var chosenLevel = 'ffl';

          function drawSecPreview(id, cvsId, isBroken) {
            var svgMap = {
              arrow_round_filled: '<svg viewBox="0 0 60 60" width="50" height="50"><line x1="30" y1="5" x2="30" y2="42" stroke="black" stroke-width="1.5"/><polygon points="24,38 36,38 30,50" fill="black"/><circle cx="30" cy="55" r="4" fill="white" stroke="black" stroke-width="1"/></svg>',
              arrow_round_hollow: '<svg viewBox="0 0 60 60" width="50" height="50"><line x1="30" y1="5" x2="30" y2="42" stroke="black" stroke-width="1.5"/><polygon points="24,38 36,38 30,50" fill="white" stroke="black" stroke-width="1.2"/><circle cx="30" cy="55" r="4" fill="white" stroke="black" stroke-width="1"/></svg>',
              arrow_diamond: '<svg viewBox="0 0 60 60" width="50" height="50"><line x1="30" y1="5" x2="30" y2="42" stroke="black" stroke-width="1.5"/><polygon points="24,38 36,38 30,50" fill="black"/><polygon points="30,50 34,55 30,60 26,55" fill="white" stroke="black" stroke-width="1"/></svg>',
              full_section: '<svg viewBox="0 0 60 60" width="50" height="50"><circle cx="30" cy="8" r="4" fill="white" stroke="black" stroke-width="1"/><polygon points="26,15 34,15 30,22" fill="black"/><line x1="30" y1="22" x2="30" y2="45" stroke="black" stroke-width="1.5" stroke-dasharray="4,2"/><polygon points="26,45 34,45 30,52" fill="black" transform="rotate(180 30 48.5)"/><circle cx="30" cy="55" r="4" fill="white" stroke="black" stroke-width="1"/></svg>',
              elevation_callout: '<svg viewBox="0 0 60 60" width="50" height="50"><text x="30" y="20" text-anchor="middle" font-family="Arial" font-size="16" font-weight="bold">A</text><polygon points="22,30 38,30 30,44" fill="black"/><line x1="30" y1="44" x2="30" y2="55" stroke="black" stroke-width="1.5"/></svg>',
              circle_only: '<svg viewBox="0 0 60 60" width="50" height="50"><circle cx="30" cy="30" r="14" fill="white" stroke="black" stroke-width="1.5"/><text x="30" y="36" text-anchor="middle" font-family="Arial" font-size="16" font-weight="bold">A</text></svg>',
              section_horizontal: '<svg viewBox="0 0 60 60" width="50" height="50"><circle cx="10" cy="30" r="6" fill="white" stroke="black" stroke-width="1.2"/><text x="10" y="34" text-anchor="middle" font-family="Arial" font-size="8" font-weight="bold">B</text><line x1="16" y1="30" x2="44" y2="30" stroke="black" stroke-width="1.5" stroke-dasharray="4,2,1,2"/><circle cx="50" cy="30" r="6" fill="white" stroke="black" stroke-width="1.2"/><text x="50" y="34" text-anchor="middle" font-family="Arial" font-size="8" font-weight="bold">B</text></svg>',
              section_bracket_round: '<svg viewBox="0 0 60 60" width="50" height="50"><line x1="24" y1="8" x2="36" y2="8" stroke="black" stroke-width="1.5"/><line x1="30" y1="8" x2="30" y2="42" stroke="black" stroke-width="1.5" stroke-dasharray="4,2,1,2"/><line x1="24" y1="42" x2="36" y2="42" stroke="black" stroke-width="1.5"/><circle cx="30" cy="52" r="5" fill="white" stroke="black" stroke-width="1.2"/><text x="30" y="55" text-anchor="middle" font-family="Arial" font-size="7" font-weight="bold">1</text></svg>',
              section_bracket_split_diamond: '<svg viewBox="0 0 60 60" width="50" height="50"><line x1="24" y1="5" x2="36" y2="5" stroke="black" stroke-width="1.5"/><line x1="30" y1="5" x2="30" y2="32" stroke="black" stroke-width="1.5"/><polygon points="24,32 36,32 30,40" fill="black"/><polygon points="30,42 40,50 30,58 20,50" fill="white" stroke="black" stroke-width="1.2"/><line x1="30" y1="42" x2="30" y2="58" stroke="black" stroke-width="1"/><text x="25" y="53" text-anchor="middle" font-family="Arial" font-size="6" font-weight="bold">A</text><text x="35" y="53" text-anchor="middle" font-family="Arial" font-size="6" font-weight="bold">A</text></svg>',
              ref_split_h_arrow: '<svg viewBox="0 0 60 60" width="50" height="50"><line x1="26" y1="6" x2="26" y2="34" stroke="black" stroke-width="1.5" stroke-dasharray="4,2,1,2"/><circle cx="26" cy="42" r="7" fill="none" stroke="black" stroke-width="1.2"/><line x1="19" y1="42" x2="33" y2="42" stroke="black" stroke-width="1"/><polygon points="32,38 32,46 42,42" fill="black"/><polygon points="22,48 30,48 26,56" fill="black"/><text x="26" y="41" text-anchor="middle" font-family="Arial" font-size="5" font-weight="bold">A</text><text x="26" y="47" text-anchor="middle" font-family="Arial" font-size="5" font-weight="bold">A1</text></svg>',
              ref_h_arrow_single: '<svg viewBox="0 0 60 60" width="50" height="50"><line x1="26" y1="6" x2="26" y2="34" stroke="black" stroke-width="1.5" stroke-dasharray="4,2,1,2"/><circle cx="26" cy="42" r="7" fill="none" stroke="black" stroke-width="1.2"/><polygon points="32,38 32,46 42,42" fill="black"/><polygon points="22,48 30,48 26,56" fill="black"/><text x="26" y="45" text-anchor="middle" font-family="Arial" font-size="8" font-weight="bold">A</text></svg>',
              ref_split_v_arrow: '<svg viewBox="0 0 60 60" width="50" height="50"><polygon points="24,6 36,6 30,14" fill="black"/><line x1="30" y1="14" x2="30" y2="36" stroke="black" stroke-width="1.5" stroke-dasharray="4,2,1,2"/><circle cx="30" cy="46" r="8" fill="white" stroke="black" stroke-width="1.2"/><line x1="30" y1="38" x2="30" y2="54" stroke="black" stroke-width="1"/><polygon points="26,54 34,54 30,60" fill="black"/><text x="26" y="49" text-anchor="middle" font-family="Arial" font-size="5" font-weight="bold">A1</text><text x="34" y="49" text-anchor="middle" font-family="Arial" font-size="5" font-weight="bold">A1</text></svg>',
              ref_aa_directional: '<svg viewBox="0 0 60 60" width="50" height="50"><text x="20" y="12" text-anchor="middle" font-family="Arial" font-size="9" font-weight="bold">A</text><polyline points="30,4 30,10 38,10" fill="none" stroke="black" stroke-width="1.2"/><polygon points="38,7 44,10 38,13" fill="black"/><line x1="30" y1="4" x2="30" y2="56" stroke="black" stroke-width="1.5" stroke-dasharray="4,2,1,2"/><text x="20" y="58" text-anchor="middle" font-family="Arial" font-size="9" font-weight="bold">A</text><polyline points="30,56 30,50 38,50" fill="none" stroke="black" stroke-width="1.2"/><polygon points="38,47 44,50 38,53" fill="black"/></svg>',
              side_arrow_dual: '<svg viewBox="0 0 60 60" width="50" height="50"><circle cx="8" cy="10" r="4" fill="white" stroke="black" stroke-width="1"/><text x="8" y="13" text-anchor="middle" font-family="Arial" font-size="6" font-weight="bold">A</text><polygon points="16,10 22,7 22,13" fill="black"/><line x1="22" y1="10" x2="30" y2="10" stroke="black" stroke-width="1.2"/><line x1="30" y1="10" x2="30" y2="50" stroke="black" stroke-width="1.5" stroke-dasharray="4,2,1,2"/><circle cx="8" cy="50" r="4" fill="white" stroke="black" stroke-width="1"/><text x="8" y="53" text-anchor="middle" font-family="Arial" font-size="6" font-weight="bold">A</text><polygon points="16,50 22,47 22,53" fill="black"/><line x1="22" y1="50" x2="30" y2="50" stroke="black" stroke-width="1.2"/></svg>',
              side_arrow_bracket: '<svg viewBox="0 0 60 60" width="50" height="50"><circle cx="8" cy="10" r="4" fill="white" stroke="black" stroke-width="1"/><text x="8" y="13" text-anchor="middle" font-family="Arial" font-size="6" font-weight="bold">B</text><polygon points="16,10 22,7 22,13" fill="black"/><line x1="22" y1="10" x2="30" y2="10" stroke="black" stroke-width="1.2"/><line x1="30" y1="10" x2="30" y2="50" stroke="black" stroke-width="1.5" stroke-dasharray="4,2,1,2"/><line x1="24" y1="50" x2="36" y2="50" stroke="black" stroke-width="1.5"/></svg>'
            };
            return svgMap[id] || '';
          }

          function drawLvlPreview(id) {
            var svgMap = {
              ffl: '<svg viewBox="0 0 60 60" width="50" height="50"><circle cx="30" cy="30" r="12" fill="white" stroke="black" stroke-width="1.5"/><line x1="18" y1="30" x2="42" y2="30" stroke="black"/><line x1="30" y1="18" x2="30" y2="42" stroke="black"/><text x="24" y="26" font-size="7" fill="black">FFL</text></svg>',
              ssl: '<svg viewBox="0 0 60 60" width="50" height="50"><circle cx="30" cy="30" r="12" fill="white" stroke="black" stroke-width="1.5"/><line x1="18" y1="30" x2="42" y2="30" stroke="black"/><line x1="30" y1="18" x2="30" y2="42" stroke="black"/><text x="24" y="26" font-size="7" fill="black">SSL</text></svg>',
              datum: '<svg viewBox="0 0 60 60" width="50" height="50"><circle cx="30" cy="30" r="12" fill="white" stroke="black" stroke-width="1.5"/><line x1="18" y1="30" x2="42" y2="30" stroke="black"/><line x1="30" y1="18" x2="30" y2="42" stroke="black"/><text x="20" y="26" font-size="6" fill="black">DATUM</text></svg>',
              parapet: '<svg viewBox="0 0 60 60" width="50" height="50"><line x1="5" y1="30" x2="55" y2="30" stroke="black" stroke-width="1" stroke-dasharray="4,2"/><polygon points="24,26 36,26 30,32" fill="white" stroke="black" stroke-width="1"/><text x="30" y="45" text-anchor="middle" font-size="7">+00.000M</text></svg>',
              cross: '<svg viewBox="0 0 60 60" width="50" height="50"><line x1="20" y1="30" x2="40" y2="30" stroke="black" stroke-width="1.5"/><line x1="30" y1="20" x2="30" y2="40" stroke="black" stroke-width="1.5"/><text x="30" y="52" text-anchor="middle" font-size="7">FFL</text></svg>',
              ffl_ssl_split: '<svg viewBox="0 0 60 60" width="50" height="50"><circle cx="30" cy="30" r="12" fill="white" stroke="black" stroke-width="1.5"/><line x1="18" y1="30" x2="42" y2="30" stroke="black" stroke-width="1"/><text x="30" y="28" text-anchor="middle" font-size="7" font-weight="bold">FFL</text><text x="30" y="40" text-anchor="middle" font-size="7" font-weight="bold">SSL</text></svg>'
            };
            return svgMap[id] || '';
          }

          function renderSections() {
            var box = document.getElementById('sec-styles');
            box.innerHTML = '';
            SEC_STYLES.forEach(function(s) {
              var el = document.createElement('div');
              el.className = 'style-card' + (s.id === chosenSection ? ' active' : '');
              el.innerHTML = '<div class="style-preview">' + drawSecPreview(s.id) + '</div>' + s.name;
              el.onclick = function() { chosenSection = s.id; renderSections(); updateSecLabels(); };
              box.appendChild(el);
            });
            updateSecLabels();
          }

          // Show or hide the dot-count dropdown alongside the "Broken" checkbox.
          function toggleDotCount() {
            var checked = document.getElementById('sec-broken').checked;
            document.getElementById('sec-dotcount').style.display = checked ? '' : 'none';
          }

          // Show a second label input only for the split-circle reference styles
          // that carry two labels (e.g. "1" over "A1", or "A1" | "A1").
          function updateSecLabels() {
            var s = SEC_STYLES.find(function(x){ return x.id === chosenSection; });
            var row2 = document.getElementById('sec-label2-row');
            if (!row2) return;
            if (s && s.split) {
              row2.style.display = '';
              document.getElementById('sec-label1-lbl').textContent =
                s.split === 'h' ? 'Top label:' : 'Left label:';
              document.getElementById('sec-label2-lbl').textContent =
                s.split === 'h' ? 'Bottom label:' : 'Right label:';
            } else {
              row2.style.display = 'none';
              document.getElementById('sec-label1-lbl').textContent = 'Label (A, B, 1, 2 ...):';
            }
          }

          function renderLevels() {
            var box = document.getElementById('lvl-styles');
            box.innerHTML = '';
            LVL_STYLES.forEach(function(s) {
              var el = document.createElement('div');
              el.className = 'style-card' + (s.id === chosenLevel ? ' active' : '');
              el.innerHTML = '<div class="style-preview">' + drawLvlPreview(s.id) + '</div>' + s.name;
              el.onclick = function() { chosenLevel = s.id; renderLevels(); };
              box.appendChild(el);
            });
          }

          var currentTab = 'sec';
          function showTab(id) {
            currentTab = id;
            document.querySelectorAll('.tab').forEach(function(t){ t.classList.remove('active'); });
            document.querySelectorAll('.panel').forEach(function(p){ p.classList.remove('active'); });
            document.querySelector('.tab:nth-child(' + ({sec:1,grid:2,lvl:3}[id]) + ')').classList.add('active');
            document.getElementById('panel-' + id).classList.add('active');
            document.getElementById('place-btn').textContent = ({sec:'Place Marker', grid:'Place Grid', lvl:'Place Marker'})[id];
          }

          function placeCurrent() {
            if (currentTab === 'sec')  return placeSection();
            if (currentTab === 'grid') return placeGrid();
            if (currentTab === 'lvl')  return placeLevel();
          }

          function toggleAdvanced() {
            var adv = document.getElementById('g-adv').checked;
            document.getElementById('g-adv-panel').style.display = adv ? 'block' : 'none';
            if (adv) rebuildAdvancedTable();
          }

          function rebuildAdvancedTable() {
            var cols = parseInt(document.getElementById('g-cols').value) || 2;
            var rows = parseInt(document.getElementById('g-rows').value) || 2;
            var hs = parseFloat(document.getElementById('g-hspace').value) || 2000;
            var vs = parseFloat(document.getElementById('g-vspace').value) || 2000;

            var colHtml = '';
            for (var i = 0; i < cols - 1; i++) {
              var lbl = String.fromCharCode(65 + i) + '-' + String.fromCharCode(66 + i);
              colHtml += '<div class="adv-row"><label>' + lbl + ':</label><input type="number" class="ac" value="' + hs + '" step="50" min="1"></div>';
            }
            document.getElementById('g-adv-cols').innerHTML = colHtml;

            var rowHtml = '';
            for (var i = 0; i < rows - 1; i++) {
              var lbl = (i+1) + '-' + (i+2);
              rowHtml += '<div class="adv-row"><label>' + lbl + ':</label><input type="number" class="ar" value="' + vs + '" step="50" min="1"></div>';
            }
            document.getElementById('g-adv-rows').innerHTML = rowHtml;
          }

          ['g-cols','g-rows','g-hspace','g-vspace'].forEach(function(id){
            document.getElementById(id).addEventListener('input', function(){
              if (document.getElementById('g-adv').checked) rebuildAdvancedTable();
            });
          });

          function placeSection() {
            var lbl  = document.getElementById('sec-label').value  || 'A';
            var lbl2 = document.getElementById('sec-label2').value || lbl;
            var broken = document.getElementById('sec-broken').checked;
            var dotCount = parseInt(document.getElementById('sec-dotcount').value) || 1;
            sketchup.place_section(chosenSection, lbl, broken, lbl2, dotCount);
          }

          function placeGrid() {
            var cfg = {
              cols: parseInt(document.getElementById('g-cols').value),
              rows: parseInt(document.getElementById('g-rows').value),
              line: document.getElementById('g-line').value,
              marker: document.getElementById('g-marker').value,
              hspace: parseFloat(document.getElementById('g-hspace').value),
              vspace: parseFloat(document.getElementById('g-vspace').value),
              text_size: document.getElementById('g-textsize').value,
              advanced: document.getElementById('g-adv').checked,
              col_gaps: [],
              row_gaps: []
            };
            if (cfg.advanced) {
              document.querySelectorAll('.ac').forEach(function(el){ cfg.col_gaps.push(parseFloat(el.value) || cfg.hspace); });
              document.querySelectorAll('.ar').forEach(function(el){ cfg.row_gaps.push(parseFloat(el.value) || cfg.vspace); });
            }
            sketchup.place_grid(JSON.stringify(cfg));
          }

          function placeLevel() {
            var elev = document.getElementById('lvl-elev').value || '+00.000M';
            sketchup.place_level(chosenLevel, elev);
          }

          renderSections();
          renderLevels();
        </script>
        </body>
        </html>
      HTML
    end

    # =========================================================================
    # SECTION MARKERS
    # =========================================================================
    module Sections
      def self.start_placement(style, label, broken, label2 = nil, dot_count = 1)
        Sketchup.set_status_text('Click to place section marker (Esc to cancel)')
        Sketchup.active_model.select_tool(
          PlaceTool.new(style, label, broken, label2 || label, dot_count)
        )
      end

      # Build a section marker group at world position pt.
      # `label2` is only used by the reference-sheet split-circle styles
      # (ref_split_h_arrow / ref_split_v_arrow). Other styles ignore it.
      # `dot_count` controls the chain-dot pattern (1..3) and is scoped so it
      # doesn't leak into unrelated draw_chain_dot callers.
      def self.build(style, label, broken, pt, view = nil, label2 = nil, dot_count = 1)
        label2 ||= label
        model = Sketchup.active_model
        model.start_operation('Place Section Marker', true)
        # Single-point placement path only used by tools that don't accept
        # a two-point form. Two-point markers (the vast majority) now derive
        # their size from the user's click distance in build_two_point,
        # eliminating any dependence on view zoom. For truly one-point
        # placements we fall back to the view-based multiplier so at least
        # something sensible appears.
        paper_mult = SketchDraw::State.paper_scale_multiplier_at(model, pt)
        SectionGrid.with_size_mult(paper_mult) do
        SectionGrid.with_dot_count(dot_count) do
        begin
          grp = model.active_entities.add_group
          grp.name = "SketchDraw_Section_#{style}_#{label}"
          grp.set_attribute(SectionGrid::ATTR_NS, 'type', 'section_marker')
          case style
          when 'arrow_round_filled'
            build_arrow(grp, label, broken, filled: true, shape: :round)
          when 'arrow_round_hollow'
            build_arrow(grp, label, broken, filled: false, shape: :round)
          when 'arrow_diamond'
            build_arrow(grp, label, broken, filled: true, shape: :diamond)
          when 'full_section'
            build_full_section(grp, label, broken)
          when 'elevation_callout'
            build_elevation_callout(grp, label)
          when 'circle_only'
            build_circle_label(grp, label)
          when 'section_horizontal'
            build_horizontal_section(grp, label, broken)
          when 'section_bracket_round'
            build_bracket_round_section(grp, label, broken)
          when 'section_bracket_split_diamond'
            build_bracket_split_diamond(grp, label, broken)
          when 'ref_split_h_arrow'
            build_ref_split_h_arrow(grp, label, label2, broken)
          when 'ref_h_arrow_single'
            build_ref_h_arrow_single(grp, label, broken)
          when 'ref_split_v_arrow'
            build_ref_split_v_arrow(grp, label, label2, broken)
          when 'ref_aa_directional'
            build_ref_aa_directional(grp, label, broken)
          when 'ref_bb_horizontal'
            build_ref_bb_horizontal(grp, label, broken)
          when 'side_arrow_dual'
            build_side_arrow_dual(grp, label, broken)
          when 'side_arrow_bracket'
            build_side_arrow_bracket(grp, label, broken)
          end
          # Translate the group to the click position. Sizing is baked
          # into local geometry by each build_* helper via size_mult, so
          # no scaling transformation is needed on the group itself. This
          # avoids SketchUp's silent-drop of faces/text inside a scaled
          # group — the reason previous versions rendered only the shaft
          # edge on world-scale placements.
          grp.transformation = Geom::Transformation.translation(
            Geom::Vector3d.new(pt.x, pt.y, 0)
          )
          model.commit_operation
        rescue => e
          model.abort_operation rescue nil
          UI.messagebox("Section marker failed: #{e.message}")
        end
        end
        end
      end

      # Common arrow style: vertical shaft + head + circle/diamond label at bottom
      def self.build_arrow(grp, label, broken, filled:, shape:)
        ents = grp.entities
        m    = SectionGrid.size_mult
        len   = SectionGrid::ARROW_LEN.mm  * m
        head  = SectionGrid::ARROW_HEAD.mm * m
        r     = SectionGrid::CIRCLE_R.mm   * m

        # Shaft (from top to head base)
        y_top  = len
        y_base = head
        SectionGrid.draw_line(ents, [0, y_top, 0], [0, y_base, 0], broken: broken)

        # Arrow head triangle (points down)
        pts = [
          Geom::Point3d.new(-head/2.0, y_base, 0),
          Geom::Point3d.new( head/2.0, y_base, 0),
          Geom::Point3d.new(0,          0,     0)
        ]
        if filled
          face = ents.add_face(pts)
          face.material = 'black' if face
          face.back_material = 'black' if face
        else
          ents.add_line(pts[0], pts[1])
          ents.add_line(pts[1], pts[2])
          ents.add_line(pts[2], pts[0])
        end

        # Label below the arrow tip
        label_y = -r - 1.mm * m
        if shape == :round
          SectionGrid.draw_circle_label(ents, [0, label_y, 0], r, label)
        else
          SectionGrid.draw_diamond_label(ents, [0, label_y, 0], r, label)
        end
      end
      private_class_method :build_arrow

      # Full A-A section line: circle+arrow at top, chain-dot line down, arrow+circle at bottom
      def self.build_full_section(grp, label, broken)
        ents = grp.entities
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm   * m
        head = SectionGrid::ARROW_HEAD.mm * m
        # Total span: 60mm on paper
        span = 60.mm * m
        top_c  = span
        top_a  = span - r*2
        mid_up = top_a - head
        bot_a  = r*2
        bot_dn = bot_a + head
        bot_c  = 0

        # Top circle + top arrow head (pointing UP)
        SectionGrid.draw_circle_label(ents, [0, top_c, 0], r, label)
        pts_up = [
          Geom::Point3d.new(-head/2.0, mid_up, 0),
          Geom::Point3d.new( head/2.0, mid_up, 0),
          Geom::Point3d.new(0,         top_a,  0)
        ]
        face = ents.add_face(pts_up); face.material = 'black' if face; face.back_material = 'black' if face

        # Middle chain-dot / solid line
        SectionGrid.draw_line(ents, [0, mid_up, 0], [0, bot_dn, 0], broken: broken)

        # Bottom arrow head (pointing DOWN) + bottom circle
        pts_dn = [
          Geom::Point3d.new(-head/2.0, bot_dn, 0),
          Geom::Point3d.new( head/2.0, bot_dn, 0),
          Geom::Point3d.new(0,         bot_a,  0)
        ]
        face2 = ents.add_face(pts_dn); face2.material = 'black' if face2; face2.back_material = 'black' if face2

        SectionGrid.draw_circle_label(ents, [0, bot_c, 0], r, label)
      end
      private_class_method :build_full_section

      # Elevation callout: letter above, filled triangle, short vertical below
      def self.build_elevation_callout(grp, label)
        ents = grp.entities
        m    = SectionGrid.size_mult
        head = SectionGrid::ARROW_HEAD.mm * m
        # Letter above
        tp = Geom::Point3d.new(0, 12.mm * m, 0)
        txt = ents.add_text(label, tp)
        # Filled triangle pointing down
        pts = [
          Geom::Point3d.new(-head/2.0, 6.mm * m, 0),
          Geom::Point3d.new( head/2.0, 6.mm * m, 0),
          Geom::Point3d.new(0,         0,    0)
        ]
        face = ents.add_face(pts); face.material = 'black' if face; face.back_material = 'black' if face
        # short vertical below the tip
        ents.add_line(Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(0, -5.mm * m, 0))
      end
      private_class_method :build_elevation_callout

      # Just a circle with a letter/number, for compact reference labels
      def self.build_circle_label(grp, label)
        m = SectionGrid.size_mult
        SectionGrid.draw_circle_label(grp.entities, [0, 0, 0], SectionGrid::CIRCLE_R.mm * m, label)
      end
      private_class_method :build_circle_label

      # ── Client-image styles (added to match the reference sheet) ────
      # Horizontal section line with a round label at each end (e.g. B-B).
      def self.build_horizontal_section(grp, label, broken)
        ents = grp.entities
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm * m
        span = 40.mm * m
        left_x  = 0
        right_x = span
        # Chain-dot (or solid) shaft between the two circles.
        SectionGrid.draw_line(ents, [left_x + r, 0, 0], [right_x - r, 0, 0], broken: broken)
        SectionGrid.draw_circle_label(ents, [left_x,  0, 0], r, label)
        SectionGrid.draw_circle_label(ents, [right_x, 0, 0], r, label)
      end
      private_class_method :build_horizontal_section

      # Vertical section with bracket (short tick-mark) ends and a round
      # label below — matches the reference sheet's first style.
      def self.build_bracket_round_section(grp, label, broken)
        ents      = grp.entities
        m         = SectionGrid.size_mult
        len       = SectionGrid::ARROW_LEN.mm * m
        r         = SectionGrid::CIRCLE_R.mm  * m
        bracket_w = 4.mm * m
        y_top    = len
        y_bottom = 0.0

        # Top and bottom bracket ticks
        ents.add_line([-bracket_w / 2.0, y_top,    0], [bracket_w / 2.0, y_top,    0])
        ents.add_line([-bracket_w / 2.0, y_bottom, 0], [bracket_w / 2.0, y_bottom, 0])

        # Vertical shaft (chain-dot when broken)
        SectionGrid.draw_line(ents, [0, y_top, 0], [0, y_bottom, 0], broken: broken)

        # Round label below the lower bracket
        SectionGrid.draw_circle_label(ents, [0, -r - 1.mm * m, 0], r, label)
      end
      private_class_method :build_bracket_round_section

      # Vertical section with bracket top, filled arrow head, and a
      # split-diamond label (two half-cells sharing one label) — matches
      # the reference sheet's second style.
      def self.build_bracket_split_diamond(grp, label, broken)
        ents      = grp.entities
        m         = SectionGrid.size_mult
        len       = SectionGrid::ARROW_LEN.mm  * m
        head      = SectionGrid::ARROW_HEAD.mm * m
        r         = SectionGrid::CIRCLE_R.mm   * m
        bracket_w = 4.mm * m
        y_top    = len
        y_arrow  = head

        # Top bracket tick
        ents.add_line([-bracket_w / 2.0, y_top, 0], [bracket_w / 2.0, y_top, 0])

        # Vertical shaft from top bracket down to the arrow base
        SectionGrid.draw_line(ents, [0, y_top, 0], [0, y_arrow, 0], broken: broken)

        # Filled arrow head pointing down
        pts = [
          Geom::Point3d.new(-head / 2.0, y_arrow, 0),
          Geom::Point3d.new( head / 2.0, y_arrow, 0),
          Geom::Point3d.new(0,           0,       0)
        ]
        face = ents.add_face(pts)
        if face
          face.material      = 'black'
          face.back_material = 'black'
        end

        # Split diamond below the arrow tip
        cy = -r - 1.mm * m
        d = [
          Geom::Point3d.new(0,     cy + r, 0),
          Geom::Point3d.new( r,    cy,     0),
          Geom::Point3d.new(0,     cy - r, 0),
          Geom::Point3d.new(-r,    cy,     0)
        ]
        d.each_with_index { |p, i| ents.add_line(p, d[(i + 1) % 4]) }
        # Vertical divider through the diamond
        ents.add_line(d[0], d[2])

        # A label per half — same value on both sides, matching the ref sheet
        half_r = r * 0.6
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new(-r * 0.5, cy, 0), half_r, label)
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new( r * 0.5, cy, 0), half_r, label)
      end
      private_class_method :build_bracket_split_diamond

      # ── Reference-sheet-exact styles ────────────────────────────────

      # Split-H circle with a big RIGHT-pointing black polygon behind it.
      # The polygon is "triangle minus right half of the disk" — the overlap
      # region has been geometrically subtracted, so only the parts of the
      # triangle OUTSIDE the circle remain: the top-left wing (above the
      # circle), the bottom-left wing (below), and the arrow tip (right).
      # Everything is drawn at Z=0 (no depth trickery).
      #
      #        ⌵           <- top wing (base extends above circle top)
      #     ╱─────╲
      #    │   A   │▶      <- arrow tip protrudes right
      #    │───────│
      #    │  A1   │
      #     ╲─────╱
      #        ⌵           <- bottom wing (base extends below circle bottom)
      # v5.74: single-label variant of draw_split_h_with_wedges — same
      # wedge (arrow + downward triangle) geometry, but no horizontal
      # divider inside the circle and only one centred label. Requested
      # by D as the 4th item in the Section list.
      def self.draw_h_wedges_single(ents, center, r, label)
        c       = Geom::Point3d.new(*center)
        h       = r * 1.35
        tip_len = r * 0.6

        pts = [Geom::Point3d.new(c.x, c.y + h, 0)]
        angle = 90
        while angle >= -90
          rad = angle * Math::PI / 180.0
          pts << Geom::Point3d.new(c.x + r * Math.cos(rad),
                                    c.y + r * Math.sin(rad), 0)
          angle -= 15
        end
        pts << Geom::Point3d.new(c.x, c.y - h, 0)
        pts << Geom::Point3d.new(c.x + r + tip_len, c.y, 0)

        blacken_face(ents.add_face(pts))
        ents.add_circle(c, Geom::Vector3d.new(0, 0, 1), r, 24)
        # NO horizontal divider (unlike draw_split_h_with_wedges).
        # ONE label centred on the circle centre.
        SectionGrid.draw_centered_label(ents, c, r * 0.55, label)
      end
      private_class_method :draw_h_wedges_single

      def self.draw_split_h_with_wedges(ents, center, r, label_top, label_bot)
        c       = Geom::Point3d.new(*center)
        # Triangle base extends h ABOVE and BELOW circle centre. h > r so
        # the top/bottom wings poke out of the circle. Tip extends far right.
        h       = r * 1.35
        tip_len = r * 0.6

        # Build the polygon boundary CCW around the visible black region.
        # 1. Start at top of base (above circle top).
        # 2. Follow the RIGHT half of the circle arc from 90° through 0°
        #    to -90° — this is the "bite" removed by the disk.
        # 3. Bottom of base (below circle bottom).
        # 4. Tip (far right), then close back to top.
        # The 15° arc step matches the 24-segment circle so shared edges
        # merge cleanly with the circle outline drawn afterward.
        pts = [Geom::Point3d.new(c.x, c.y + h, 0)]
        angle = 90
        while angle >= -90
          rad = angle * Math::PI / 180.0
          pts << Geom::Point3d.new(c.x + r * Math.cos(rad),
                                    c.y + r * Math.sin(rad), 0)
          angle -= 15
        end
        pts << Geom::Point3d.new(c.x, c.y - h, 0)
        pts << Geom::Point3d.new(c.x + r + tip_len, c.y, 0)

        blacken_face(ents.add_face(pts))

        # ── Circle outline — LEFT arcs are new; RIGHT arcs merge with the
        #    polygon boundary above.
        ents.add_circle(c, Geom::Vector3d.new(0, 0, 1), r, 24)

        # Horizontal divider inside circle
        ents.add_line([c.x - r, c.y, 0], [c.x + r, c.y, 0])

        # Labels
        SectionGrid.draw_centered_label(
          ents, Geom::Point3d.new(c.x, c.y + r * 0.5, 0), r * 0.55, label_top
        )
        SectionGrid.draw_centered_label(
          ents, Geom::Point3d.new(c.x, c.y - r * 0.5, 0), r * 0.55, label_bot
        )
      end
      private_class_method :draw_split_h_with_wedges

      # Hide the chord edge of a wedge triangle so no straight line shows
      # inside the circle — only the black fill and the outward tip edges
      # remain visible. `orientation` = :vertical for the right wedge (base
      # is a vertical chord) or :horizontal for the down wedge.
      def self.hide_wedge_base_edge(face, orientation)
        return unless face
        face.edges.each do |edge|
          s = edge.start.position
          e = edge.end.position
          if orientation == :vertical   && (s.x - e.x).abs < 0.001
            edge.hidden = true
          elsif orientation == :horizontal && (s.y - e.y).abs < 0.001
            edge.hidden = true
          end
        end
      rescue
        nil
      end
      private_class_method :hide_wedge_base_edge

      def self.blacken_face(face)
        return unless face
        face.material      = 'black'
        face.back_material = 'black'
      rescue
        nil
      end
      private_class_method :blacken_face

      # Draw a split circle (either horizontal or vertical divider) at `center`,
      # with two labels sized to fit each half.
      def self.draw_split_circle(ents, center, r, label_a, label_b, orientation)
        c = Geom::Point3d.new(*center)
        ents.add_circle(c, Geom::Vector3d.new(0, 0, 1), r, 24)
        if orientation == :horizontal
          ents.add_line([c.x - r, c.y, 0], [c.x + r, c.y, 0])
          SectionGrid.draw_centered_label(ents, Geom::Point3d.new(c.x, c.y + r * 0.5, 0), r * 0.6, label_a)
          SectionGrid.draw_centered_label(ents, Geom::Point3d.new(c.x, c.y - r * 0.5, 0), r * 0.6, label_b)
        else
          ents.add_line([c.x, c.y - r, 0], [c.x, c.y + r, 0])
          SectionGrid.draw_centered_label(ents, Geom::Point3d.new(c.x - r * 0.5, c.y, 0), r * 0.6, label_a)
          SectionGrid.draw_centered_label(ents, Geom::Point3d.new(c.x + r * 0.5, c.y, 0), r * 0.6, label_b)
        end
      end
      private_class_method :draw_split_circle

      # Filled triangle helper. `dir` = :up, :down, :left, :right.
      def self.draw_filled_triangle(ents, tip, size, dir)
        s = size
        case dir
        when :down
          pts = [Geom::Point3d.new(tip.x - s, tip.y + s, 0),
                 Geom::Point3d.new(tip.x + s, tip.y + s, 0),
                 tip]
        when :up
          pts = [Geom::Point3d.new(tip.x - s, tip.y - s, 0),
                 Geom::Point3d.new(tip.x + s, tip.y - s, 0),
                 tip]
        when :right
          pts = [Geom::Point3d.new(tip.x - s, tip.y - s, 0),
                 Geom::Point3d.new(tip.x - s, tip.y + s, 0),
                 tip]
        when :left
          pts = [Geom::Point3d.new(tip.x + s, tip.y - s, 0),
                 Geom::Point3d.new(tip.x + s, tip.y + s, 0),
                 tip]
        end
        face = ents.add_face(pts)
        if face
          face.material      = 'black'
          face.back_material = 'black'
        end
      end
      private_class_method :draw_filled_triangle

      # Small L-bracket at (x,y) — reference-sheet corner tick.
      # `dir` picks which quadrant the bracket points into:
      #   :tl (⌐), :tr (¬), :bl (⌊), :br (⌋)
      def self.draw_l_bracket(ents, x, y, size, dir)
        s = size
        case dir
        when :tl
          ents.add_line([x, y, 0], [x + s, y, 0])
          ents.add_line([x, y, 0], [x, y - s, 0])
        when :tr
          ents.add_line([x - s, y, 0], [x, y, 0])
          ents.add_line([x, y, 0], [x, y - s, 0])
        when :bl
          ents.add_line([x, y, 0], [x, y + s, 0])
          ents.add_line([x, y, 0], [x + s, y, 0])
        when :br
          ents.add_line([x - s, y, 0], [x, y, 0])
          ents.add_line([x, y, 0], [x, y + s, 0])
        end
      end
      private_class_method :draw_l_bracket

      # Style 1 in the reference sheet — vertical chain-dot with an L-bracket
      # at the top and a split-H circle sitting on black wedges (right + down)
      # at the bottom.
      def self.build_ref_split_h_arrow(grp, label_top, label_bot, broken)
        ents = grp.entities
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm  * m
        len  = SectionGrid::ARROW_LEN.mm * m
        bs   = 3.mm * m

        y_top    = len
        y_bottom = 0.0
        y_circle = -r - 2.mm * m

        draw_l_bracket(ents, 0, y_top, bs, :tl)
        SectionGrid.draw_line(ents, [0, y_top - bs, 0], [0, y_bottom, 0], broken: broken)
        draw_split_h_with_wedges(ents, [0, y_circle, 0], r, label_top, label_bot)
      end
      private_class_method :build_ref_split_h_arrow

      # v5.74: single-label sibling of build_ref_split_h_arrow. Same
      # bracket + chain-dot leader + wedged circle, but the circle has
      # no horizontal divider and carries just one label.
      def self.build_ref_h_arrow_single(grp, label, broken)
        ents = grp.entities
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm  * m
        len  = SectionGrid::ARROW_LEN.mm * m
        bs   = 3.mm * m

        y_top    = len
        y_bottom = 0.0
        y_circle = -r - 2.mm * m

        draw_l_bracket(ents, 0, y_top, bs, :tl)
        SectionGrid.draw_line(ents, [0, y_top - bs, 0], [0, y_bottom, 0], broken: broken)
        draw_h_wedges_single(ents, [0, y_circle, 0], r, label)
      end
      private_class_method :build_ref_h_arrow_single

      # Style 2 in the reference sheet — filled triangle top, vertical
      # chain-dot, vertically-split circle at bottom + down triangle.
      def self.build_ref_split_v_arrow(grp, label_left, label_right, broken)
        ents = grp.entities
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm  * m
        len  = SectionGrid::ARROW_LEN.mm * m

        y_top    = len
        y_bottom = 0.0
        y_circle = -r - 2.mm * m

        # Filled triangle at top pointing down
        draw_filled_triangle(ents, Geom::Point3d.new(0, y_top, 0), 2.mm * m, :down)
        # Vertical shaft
        SectionGrid.draw_line(ents, [0, y_top - 2.mm * m, 0], [0, y_bottom, 0], broken: broken)
        # Split circle with vertical divider
        draw_split_circle(ents, [0, y_circle, 0], r, label_left, label_right, :vertical)
        # Down-pointing arrow attached to circle bottom
        tip = Geom::Point3d.new(0, y_circle - r - 3.mm * m, 0)
        draw_filled_triangle(ents, tip, 2.mm * m, :down)
      end
      private_class_method :build_ref_split_v_arrow

      # Style 3 in the reference sheet — "A" letter + L-bracket + right arrow
      # at TOP and mirrored at BOTTOM, vertical chain-dot in between.
      def self.build_ref_aa_directional(grp, label, broken)
        ents = grp.entities
        m    = SectionGrid.size_mult
        len  = SectionGrid::ARROW_LEN.mm * m
        bs   = 2.5.mm * m

        y_top    = len
        y_bottom = 0.0

        # Top marker: letter + L-bracket + triangle. Triangle is placed
        # directly at the bracket's horizontal end (no `tip_off` gap), and
        # the vertical shaft runs all the way to the bracket corner — the
        # user's "삼각형과 선이 딱 붙게 해달라" request.
        SectionGrid.draw_centered_label(
          ents, Geom::Point3d.new(-4.mm * m, y_top + 1.5.mm * m, 0), 3.mm * m, label
        )
        draw_l_bracket(ents, 0, y_top, bs, :tl)
        draw_filled_triangle(
          ents, Geom::Point3d.new(bs, y_top, 0), 1.5.mm * m, :right
        )

        # Bottom marker: letter + bracket + arrow (mirror)
        SectionGrid.draw_centered_label(
          ents, Geom::Point3d.new(-4.mm * m, y_bottom - 1.5.mm * m, 0), 3.mm * m, label
        )
        draw_l_bracket(ents, 0, y_bottom, bs, :bl)
        draw_filled_triangle(
          ents, Geom::Point3d.new(bs, y_bottom, 0), 1.5.mm * m, :right
        )

        # Vertical chain-dot shaft touches both bracket corners (no gap).
        SectionGrid.draw_line(ents, [0, y_top, 0], [0, y_bottom, 0], broken: broken)
      end
      private_class_method :build_ref_aa_directional

      # Side-arrow style: labelled circle sits BESIDE the shaft, with a
      # left-pointing filled triangle just right of the circle and a short
      # horizontal connector to the vertical shaft.
      #
      #    (A) ◁━━━━┓
      #             ┃
      #             ┃  (chain-dot shaft)
      #             ┃
      #    (A) ◁━━━━┛
      def self.build_side_arrow_dual(grp, label, broken)
        ents = grp.entities
        m    = SectionGrid.size_mult
        len  = SectionGrid::ARROW_LEN.mm * m
        r    = SectionGrid::CIRCLE_R.mm  * m / 3.0   # 1/3 of the default so it sits at ~arrow scale
        arr  = 1.5.mm * m         # arrow half-height
        gap  = 1.0.mm * m         # circle → arrow gap
        conn = 3.0.mm * m         # arrow base → shaft horizontal connector

        y_top    = len
        y_bottom = 0.0

        # Shaft at x=0. Layout to the LEFT of it: connector | arrow | gap | circle
        arrow_base_x = -conn
        arrow_tip_x  = arrow_base_x - 2 * arr
        circle_cx    = arrow_tip_x - gap - r

        [y_top, y_bottom].each do |y|
          SectionGrid.draw_circle_label(ents, [circle_cx, y, 0], r, label)
          draw_filled_triangle(ents, Geom::Point3d.new(arrow_tip_x, y, 0), arr, :left)
          ents.add_line([arrow_base_x, y, 0], [0, y, 0])
        end

        SectionGrid.draw_line(ents, [0, y_top, 0], [0, y_bottom, 0], broken: broken)
      end
      private_class_method :build_side_arrow_dual

      # Same as side_arrow_dual at the top, but the bottom is just a short
      # perpendicular bracket tick — for open-ended sections.
      #
      #    (B) ◁━━━━┓
      #             ┃
      #             ┃
      #             ┃
      #             ━┛ (short tick)
      def self.build_side_arrow_bracket(grp, label, broken)
        ents = grp.entities
        m    = SectionGrid.size_mult
        len  = SectionGrid::ARROW_LEN.mm * m
        r    = SectionGrid::CIRCLE_R.mm  * m / 3.0   # 1/3 of the default so it sits at ~arrow scale
        arr  = 1.5.mm * m
        gap  = 1.0.mm * m
        conn = 3.0.mm * m
        tick = 2.0.mm * m   # half-width of the bottom bracket tick

        y_top    = len
        y_bottom = 0.0

        arrow_base_x = -conn
        arrow_tip_x  = arrow_base_x - 2 * arr
        circle_cx    = arrow_tip_x - gap - r

        # Top: labelled circle + arrow + connector (same as dual style)
        SectionGrid.draw_circle_label(ents, [circle_cx, y_top, 0], r, label)
        draw_filled_triangle(ents, Geom::Point3d.new(arrow_tip_x, y_top, 0), arr, :left)
        ents.add_line([arrow_base_x, y_top, 0], [0, y_top, 0])

        # Bottom: short horizontal tick centred on the shaft (no label).
        ents.add_line([-tick, y_bottom, 0], [tick, y_bottom, 0])

        # Vertical chain-dot shaft
        SectionGrid.draw_line(ents, [0, y_top, 0], [0, y_bottom, 0], broken: broken)
      end
      private_class_method :build_side_arrow_bracket

      # Style 4 in the reference sheet — "B" letter + L-bracket + down arrow
      # at LEFT and mirrored at RIGHT, horizontal chain-dot in between.
      def self.build_ref_bb_horizontal(grp, label, broken)
        ents = grp.entities
        m    = SectionGrid.size_mult
        span = 40.mm * m
        bs   = 2.5.mm * m
        tip_off = 3.mm * m

        x_left  = 0.0
        x_right = span

        # Left marker: letter above, bracket, arrow pointing down
        SectionGrid.draw_centered_label(
          ents, Geom::Point3d.new(x_left, 4.mm * m, 0), 3.mm * m, label
        )
        draw_l_bracket(ents, x_left, 0, bs, :tl)
        draw_filled_triangle(
          ents, Geom::Point3d.new(x_left, -bs - tip_off, 0), 1.5.mm * m, :down
        )

        # Right marker: mirror of left
        SectionGrid.draw_centered_label(
          ents, Geom::Point3d.new(x_right, 4.mm * m, 0), 3.mm * m, label
        )
        draw_l_bracket(ents, x_right, 0, bs, :tr)
        draw_filled_triangle(
          ents, Geom::Point3d.new(x_right, -bs - tip_off, 0), 1.5.mm * m, :down
        )

        # Horizontal chain-dot shaft between the two brackets
        SectionGrid.draw_line(ents,
                              [x_left + bs, 0, 0],
                              [x_right - bs, 0, 0], broken: broken)
      end
      private_class_method :build_ref_bb_horizontal

      # ── Two-click placement — builds a section-line style between two
      # user-clicked endpoints, auto-orienting to vertical or horizontal
      # based on the click direction. Positions are converted to a local
      # coordinate system anchored at pt1, and the group is translated to
      # pt1 so its origin is at the first click point.
      def self.build_two_point(style, label, broken, pt1, pt2, label2 = nil, dot_count = 1)
        label2 ||= label
        model = Sketchup.active_model
        model.start_operation('Place Section Marker', true)

        # Detail sizes (letter, arrow head, bracket) scale with the click
        # distance so the marker keeps the same visual proportions whether
        # the user clicks 30mm apart on paper or 5m apart on a scaffold.
        # Divided by 3 so the head/label sit at ~10% of the shaft — the
        # "Word arrow" look the user asked for ("원이랑 글자, 삼각형이 너무
        # 커 — Word 방향표처럼"). Without the /3 the details were 25-30%
        # of the shaft and felt oversized.
        distance = pt1.distance(pt2)
        detail_mult = distance / SectionGrid::ARROW_LEN.mm / 3.0
        detail_mult = 1.0 if detail_mult < 1.0

        SectionGrid.with_size_mult(detail_mult) do
        SectionGrid.with_dot_count(dot_count) do
        begin
          grp = model.active_entities.add_group
          grp.name = "SketchDraw_Section_#{style}"
          grp.set_attribute(SectionGrid::ATTR_NS, 'type', 'section_marker')

          dx = pt2.x - pt1.x
          dy = pt2.y - pt1.y
          vertical = dy.abs >= dx.abs

          ents = grp.entities

          if DUAL_HEAD_STYLES.include?(style)
            # ── Dual-head styles: mirror the marker at pt2 with a line between ──
            if vertical
              y_first  = 0.0
              y_second = dy
              top_y = [y_first, y_second].max
              bot_y = [y_first, y_second].min
              top = Geom::Point3d.new(0, top_y, 0)
              bot = Geom::Point3d.new(0, bot_y, 0)
              case style
              when 'ref_aa_directional'            then draw_aa_directional_at(ents, label, broken, top, bot)
              when 'side_arrow_dual'               then draw_side_arrow_dual_at(ents, label, broken, top, bot)
              when 'side_arrow_bracket'            then draw_side_arrow_bracket_at(ents, label, broken, top, bot)
              when 'full_section'                  then draw_full_section_at(ents, label, broken, top, bot)
              when 'section_horizontal'            then draw_line_between(ents, label, broken, top, bot, :vertical)
              when 'section_bracket_round'         then draw_bracket_round_at(ents, label, broken, top, bot)
              when 'section_bracket_split_diamond' then draw_bracket_split_diamond_at(ents, label, broken, top, bot)
              end
            else
              x_left  = [0.0, dx].min
              x_right = [0.0, dx].max
              left  = Geom::Point3d.new(x_left,  0, 0)
              right = Geom::Point3d.new(x_right, 0, 0)
              case style
              when 'ref_aa_directional'            then draw_bb_horizontal_at(ents, label, broken, left, right)
              when 'side_arrow_dual'               then draw_side_arrow_dual_horizontal_at(ents, label, broken, left, right)
              when 'side_arrow_bracket'            then draw_side_arrow_bracket_horizontal_at(ents, label, broken, left, right)
              when 'section_horizontal'            then draw_line_between(ents, label, broken, left, right, :horizontal)
              when 'full_section'                  then draw_line_between(ents, label, broken, left, right, :horizontal)
              when 'section_bracket_round'         then draw_line_between(ents, label, broken, left, right, :horizontal)
              when 'section_bracket_split_diamond' then draw_line_between(ents, label, broken, left, right, :horizontal)
              end
            end
          else
            # ── Single-head styles: head at pt1 (local origin), chain-dot line
            #    extends toward pt2. The line direction (up/down/left/right)
            #    determines which side of the head the arrow sits on.
            line_dir = if vertical
                         dy >= 0 ? :up : :down
                       else
                         dx >= 0 ? :right : :left
                       end
            end_pt = vertical ? Geom::Point3d.new(0, dy, 0) : Geom::Point3d.new(dx, 0, 0)

            case style
            when 'arrow_round_filled'
              draw_arrow_head_two_point(ents, label, broken, filled: true,  shape: :round,   line_dir: line_dir, end_pt: end_pt)
            when 'arrow_round_hollow'
              draw_arrow_head_two_point(ents, label, broken, filled: false, shape: :round,   line_dir: line_dir, end_pt: end_pt)
            when 'arrow_diamond'
              draw_arrow_head_two_point(ents, label, broken, filled: true,  shape: :diamond, line_dir: line_dir, end_pt: end_pt)
            when 'elevation_callout'
              draw_elevation_callout_two_point(ents, label, broken, line_dir: line_dir, end_pt: end_pt)
            when 'circle_only'
              draw_circle_only_two_point(ents, label, broken, line_dir: line_dir, end_pt: end_pt)
            when 'ref_split_h_arrow'
              draw_ref_split_h_arrow_two_point(ents, label, label2, broken, line_dir: line_dir, end_pt: end_pt)
            when 'ref_h_arrow_single'
              draw_ref_h_arrow_single_two_point(ents, label, broken, line_dir: line_dir, end_pt: end_pt)
            when 'ref_split_v_arrow'
              draw_ref_split_v_arrow_two_point(ents, label, label2, broken, line_dir: line_dir, end_pt: end_pt)
            end
          end

          grp.transformation = Geom::Transformation.translation(Geom::Vector3d.new(pt1.x, pt1.y, 0))
          model.commit_operation
        rescue => e
          model.abort_operation rescue nil
          UI.messagebox("Section marker failed: #{e.class}: #{e.message}")
        end
        end
        end
      end

      # ── Endpoint-based drawing helpers ──────────────────────────────

      # Simple A-A directional style (matches the original 1-click
      # build_ref_aa_directional look): each endpoint gets a small letter
      # label, a tiny L-bracket, and a small right-pointing arrow. Between
      # them runs the chain-dot line whose density is controlled by the
      # dot-count dropdown.
      #
      #    A ⌐ ▶
      #      ┊
      #      ┊  (chain-dot line — dot count 1/2/3)
      #      ┊
      #    A ⌊ ▶
      def self.draw_aa_directional_at(ents, label, broken, top, bot)
        m  = SectionGrid.size_mult
        bs = 2.5.mm * m
        # Triangle attached to bracket's horizontal end (no `tip_off` gap);
        # shaft runs corner-to-corner (no `-bs` inset).
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new(top.x - 4.mm * m, top.y + 1.5.mm * m, 0), 3.mm * m, label)
        draw_l_bracket(ents, top.x, top.y, bs, :tl)
        draw_filled_triangle(ents, Geom::Point3d.new(top.x + bs, top.y, 0), 1.5.mm * m, :right)
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new(bot.x - 4.mm * m, bot.y - 1.5.mm * m, 0), 3.mm * m, label)
        draw_l_bracket(ents, bot.x, bot.y, bs, :bl)
        draw_filled_triangle(ents, Geom::Point3d.new(bot.x + bs, bot.y, 0), 1.5.mm * m, :right)
        SectionGrid.draw_line(ents, [top.x, top.y, 0], [bot.x, bot.y, 0], broken: broken)
      end
      private_class_method :draw_aa_directional_at

      # Two-point vertical form of side_arrow_dual — see build_side_arrow_dual
      # for the layout. Circles + arrows sit LEFT of the shaft at each end.
      def self.draw_side_arrow_dual_at(ents, label, broken, top, bot)
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm * m / 3.0   # smaller circle — matches build_side_arrow_*
        arr  = 1.5.mm * m
        gap  = 1.0.mm * m
        conn = 3.0.mm * m

        arrow_base_x = -conn
        arrow_tip_x  = arrow_base_x - 2 * arr
        circle_cx    = arrow_tip_x - gap - r

        [top, bot].each do |pt|
          SectionGrid.draw_circle_label(ents, [pt.x + circle_cx, pt.y, 0], r, label)
          draw_filled_triangle(ents, Geom::Point3d.new(pt.x + arrow_tip_x, pt.y, 0), arr, :left)
          ents.add_line([pt.x + arrow_base_x, pt.y, 0], [pt.x, pt.y, 0])
        end

        SectionGrid.draw_line(ents, [top.x, top.y, 0], [bot.x, bot.y, 0], broken: broken)
      end
      private_class_method :draw_side_arrow_dual_at

      # Two-point vertical form of side_arrow_bracket — top gets the labelled
      # circle + arrow like the dual style; bottom gets a short perpendicular
      # tick centred on the shaft.
      def self.draw_side_arrow_bracket_at(ents, label, broken, top, bot)
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm * m / 3.0   # smaller circle — matches build_side_arrow_*
        arr  = 1.5.mm * m
        gap  = 1.0.mm * m
        conn = 3.0.mm * m
        tick = 2.0.mm * m

        arrow_base_x = -conn
        arrow_tip_x  = arrow_base_x - 2 * arr
        circle_cx    = arrow_tip_x - gap - r

        # Top marker (labelled circle + arrow + connector)
        SectionGrid.draw_circle_label(ents, [top.x + circle_cx, top.y, 0], r, label)
        draw_filled_triangle(ents, Geom::Point3d.new(top.x + arrow_tip_x, top.y, 0), arr, :left)
        ents.add_line([top.x + arrow_base_x, top.y, 0], [top.x, top.y, 0])

        # Bottom: perpendicular tick centred on the shaft
        ents.add_line([bot.x - tick, bot.y, 0], [bot.x + tick, bot.y, 0])

        SectionGrid.draw_line(ents, [top.x, top.y, 0], [bot.x, bot.y, 0], broken: broken)
      end
      private_class_method :draw_side_arrow_bracket_at

      # Horizontal variant of side_arrow_dual — circle + up-pointing arrow at
      # each end sits ABOVE a horizontal shaft. Kept simple; users who want
      # horizontal placement of this style just click LEFT then RIGHT.
      def self.draw_side_arrow_dual_horizontal_at(ents, label, broken, left, right)
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm * m / 3.0   # smaller circle — matches build_side_arrow_*
        arr  = 1.5.mm * m
        gap  = 1.0.mm * m
        conn = 3.0.mm * m

        arrow_base_y = conn
        arrow_tip_y  = arrow_base_y + 2 * arr
        circle_cy    = arrow_tip_y + gap + r

        [left, right].each do |pt|
          SectionGrid.draw_circle_label(ents, [pt.x, pt.y + circle_cy, 0], r, label)
          draw_filled_triangle(ents, Geom::Point3d.new(pt.x, pt.y + arrow_tip_y, 0), arr, :down)
          ents.add_line([pt.x, pt.y + arrow_base_y, 0], [pt.x, pt.y, 0])
        end

        SectionGrid.draw_line(ents, [left.x, left.y, 0], [right.x, right.y, 0], broken: broken)
      end
      private_class_method :draw_side_arrow_dual_horizontal_at

      def self.draw_side_arrow_bracket_horizontal_at(ents, label, broken, left, right)
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm * m / 3.0   # smaller circle — matches build_side_arrow_*
        arr  = 1.5.mm * m
        gap  = 1.0.mm * m
        conn = 3.0.mm * m
        tick = 2.0.mm * m

        arrow_base_y = conn
        arrow_tip_y  = arrow_base_y + 2 * arr
        circle_cy    = arrow_tip_y + gap + r

        # LEFT end gets the labelled circle + arrow
        SectionGrid.draw_circle_label(ents, [left.x, left.y + circle_cy, 0], r, label)
        draw_filled_triangle(ents, Geom::Point3d.new(left.x, left.y + arrow_tip_y, 0), arr, :down)
        ents.add_line([left.x, left.y + arrow_base_y, 0], [left.x, left.y, 0])

        # RIGHT end: short perpendicular tick
        ents.add_line([right.x, right.y - tick, 0], [right.x, right.y + tick, 0])

        SectionGrid.draw_line(ents, [left.x, left.y, 0], [right.x, right.y, 0], broken: broken)
      end
      private_class_method :draw_side_arrow_bracket_horizontal_at

      # Simple B-B horizontal counterpart. Same look as the 1-click
      # build_ref_bb_horizontal — small letter, tick, and down-pointing
      # arrow at each end with a chain-dot line between.
      def self.draw_bb_horizontal_at(ents, label, broken, left, right)
        m       = SectionGrid.size_mult
        bs      = 2.5.mm * m
        tip_off = 3.mm * m
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new(left.x, 4.mm * m, 0), 3.mm * m, label)
        draw_l_bracket(ents, left.x, 0, bs, :tl)
        draw_filled_triangle(ents, Geom::Point3d.new(left.x, -bs - tip_off, 0), 1.5.mm * m, :down)
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new(right.x, 4.mm * m, 0), 3.mm * m, label)
        draw_l_bracket(ents, right.x, 0, bs, :tr)
        draw_filled_triangle(ents, Geom::Point3d.new(right.x, -bs - tip_off, 0), 1.5.mm * m, :down)
        SectionGrid.draw_line(ents, [left.x + bs, 0, 0], [right.x - bs, 0, 0], broken: broken)
      end
      private_class_method :draw_bb_horizontal_at

      def self.draw_line_between(ents, label, broken, p1, p2, orientation)
        m = SectionGrid.size_mult
        r = SectionGrid::CIRCLE_R.mm * m
        SectionGrid.draw_circle_label(ents, [p1.x, p1.y, 0], r, label)
        SectionGrid.draw_circle_label(ents, [p2.x, p2.y, 0], r, label)
        if orientation == :vertical
          SectionGrid.draw_line(ents, [p1.x, p1.y - r, 0], [p2.x, p2.y + r, 0], broken: broken)
        else
          SectionGrid.draw_line(ents, [p1.x + r, p1.y, 0], [p2.x - r, p2.y, 0], broken: broken)
        end
      end
      private_class_method :draw_line_between

      def self.draw_bracket_round_at(ents, label, broken, top, bot)
        m         = SectionGrid.size_mult
        r         = SectionGrid::CIRCLE_R.mm * m
        bracket_w = 4.mm * m
        ents.add_line([top.x - bracket_w / 2.0, top.y, 0], [top.x + bracket_w / 2.0, top.y, 0])
        ents.add_line([bot.x - bracket_w / 2.0, bot.y, 0], [bot.x + bracket_w / 2.0, bot.y, 0])
        SectionGrid.draw_line(ents, [top.x, top.y, 0], [bot.x, bot.y, 0], broken: broken)
        SectionGrid.draw_circle_label(ents, [bot.x, bot.y - r - 1.mm * m, 0], r, label)
      end
      private_class_method :draw_bracket_round_at

      def self.draw_bracket_split_diamond_at(ents, label, broken, top, bot)
        m         = SectionGrid.size_mult
        head      = SectionGrid::ARROW_HEAD.mm * m
        r         = SectionGrid::CIRCLE_R.mm * m
        bracket_w = 4.mm * m
        ents.add_line([top.x - bracket_w / 2.0, top.y, 0], [top.x + bracket_w / 2.0, top.y, 0])
        SectionGrid.draw_line(ents, [top.x, top.y, 0], [bot.x, bot.y + head, 0], broken: broken)
        pts = [
          Geom::Point3d.new(bot.x - head / 2.0, bot.y + head, 0),
          Geom::Point3d.new(bot.x + head / 2.0, bot.y + head, 0),
          Geom::Point3d.new(bot.x,              bot.y,        0)
        ]
        face = ents.add_face(pts)
        if face
          face.material      = 'black'
          face.back_material = 'black'
        end
        cy = bot.y - r - 1.mm * m
        d  = [
          Geom::Point3d.new(bot.x,      cy + r, 0),
          Geom::Point3d.new(bot.x + r,  cy,     0),
          Geom::Point3d.new(bot.x,      cy - r, 0),
          Geom::Point3d.new(bot.x - r,  cy,     0)
        ]
        d.each_with_index { |p, i| ents.add_line(p, d[(i + 1) % 4]) }
        ents.add_line(d[0], d[2])
        half_r = r * 0.6
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new(bot.x - r * 0.5, cy, 0), half_r, label)
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new(bot.x + r * 0.5, cy, 0), half_r, label)
      end
      private_class_method :draw_bracket_split_diamond_at

      # ── Single-head 2-click helpers ─────────────────────────────────
      # Each helper draws the head at LOCAL (0,0) with an arrow (or wedges)
      # oriented AWAY from the direction the line extends, then draws a
      # chain-dot line from just past the head to `end_pt`.

      # Given the line direction, return the offset from the head centre
      # where the chain-dot line should START from (just past the head).
      def self.line_offset_for(line_dir, dist)
        case line_dir
        when :up    then Geom::Point3d.new(0,  dist, 0)
        when :down  then Geom::Point3d.new(0, -dist, 0)
        when :right then Geom::Point3d.new( dist, 0, 0)
        when :left  then Geom::Point3d.new(-dist, 0, 0)
        end
      end
      private_class_method :line_offset_for

      # Draw a filled or hollow triangle "arrow head" whose TIP touches the
      # head/label and whose BASE faces the line. Returns the base centre so
      # the caller can start the chain-dot line from there.
      def self.draw_arrow_between(ents, label_edge_offset, head_size, line_dir, filled)
        # `label_edge_offset` = distance from origin to the near side of the
        # arrow (i.e., where the head/label ends).
        case line_dir
        when :up
          tip  = Geom::Point3d.new(0,  label_edge_offset, 0)
          base = Geom::Point3d.new(0,  label_edge_offset + head_size, 0)
          b1   = Geom::Point3d.new(-head_size / 2.0, base.y, 0)
          b2   = Geom::Point3d.new( head_size / 2.0, base.y, 0)
        when :down
          tip  = Geom::Point3d.new(0, -label_edge_offset, 0)
          base = Geom::Point3d.new(0, -label_edge_offset - head_size, 0)
          b1   = Geom::Point3d.new(-head_size / 2.0, base.y, 0)
          b2   = Geom::Point3d.new( head_size / 2.0, base.y, 0)
        when :right
          tip  = Geom::Point3d.new( label_edge_offset, 0, 0)
          base = Geom::Point3d.new( label_edge_offset + head_size, 0, 0)
          b1   = Geom::Point3d.new(base.x, -head_size / 2.0, 0)
          b2   = Geom::Point3d.new(base.x,  head_size / 2.0, 0)
        when :left
          tip  = Geom::Point3d.new(-label_edge_offset, 0, 0)
          base = Geom::Point3d.new(-label_edge_offset - head_size, 0, 0)
          b1   = Geom::Point3d.new(base.x, -head_size / 2.0, 0)
          b2   = Geom::Point3d.new(base.x,  head_size / 2.0, 0)
        end
        pts = [tip, b1, b2]
        if filled
          face = ents.add_face(pts)
          if face
            face.material      = 'black'
            face.back_material = 'black'
          end
        else
          (0..2).each { |i| ents.add_line(pts[i], pts[(i + 1) % 3]) }
        end
        base
      end
      private_class_method :draw_arrow_between

      # arrow_round_filled / arrow_round_hollow / arrow_diamond
      # Head = round or diamond label at origin. Arrow between head and line.
      def self.draw_arrow_head_two_point(ents, label, broken, filled:, shape:, line_dir:, end_pt:)
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm   * m
        head = SectionGrid::ARROW_HEAD.mm * m

        # Head label at origin
        if shape == :diamond
          SectionGrid.draw_diamond_label(ents, [0, 0, 0], r, label)
        else
          SectionGrid.draw_circle_label(ents, [0, 0, 0], r, label)
        end

        # Arrow between head and line, base is where line starts
        line_start = draw_arrow_between(ents, r + 1.mm * m, head, line_dir, filled)
        SectionGrid.draw_line(ents, [line_start.x, line_start.y, 0], [end_pt.x, end_pt.y, 0], broken: broken)
      end
      private_class_method :draw_arrow_head_two_point

      # circle_only — just a circle at pt1, chain-dot line from circle edge to pt2.
      def self.draw_circle_only_two_point(ents, label, broken, line_dir:, end_pt:)
        m = SectionGrid.size_mult
        r = SectionGrid::CIRCLE_R.mm * m
        SectionGrid.draw_circle_label(ents, [0, 0, 0], r, label)
        line_start = line_offset_for(line_dir, r)
        SectionGrid.draw_line(ents, [line_start.x, line_start.y, 0], [end_pt.x, end_pt.y, 0], broken: broken)
      end
      private_class_method :draw_circle_only_two_point

      # elevation_callout — big letter + filled arrow at pt1, line to pt2.
      def self.draw_elevation_callout_two_point(ents, label, broken, line_dir:, end_pt:)
        m    = SectionGrid.size_mult
        head = SectionGrid::ARROW_HEAD.mm * m
        # Big letter on one side of the arrow (opposite the line direction)
        letter_offset = case line_dir
                        when :up    then Geom::Point3d.new(0, -8.mm * m, 0)
                        when :down  then Geom::Point3d.new(0,  8.mm * m, 0)
                        when :right then Geom::Point3d.new(-8.mm * m, 0, 0)
                        when :left  then Geom::Point3d.new( 8.mm * m, 0, 0)
                        end
        SectionGrid.draw_centered_label(ents, letter_offset, 5.mm * m, label)
        line_start = draw_arrow_between(ents, 2.mm * m, head, line_dir, true)
        SectionGrid.draw_line(ents, [line_start.x, line_start.y, 0], [end_pt.x, end_pt.y, 0], broken: broken)
      end
      private_class_method :draw_elevation_callout_two_point

      # ref_split_h_arrow (updated visual): split-H circle sitting on black
      # wedges. Head at pt1, chain-dot line extends to pt2, terminated by an
      # L-bracket tick facing the head.
      def self.draw_ref_split_h_arrow_two_point(ents, label_top, label_bot, broken, line_dir:, end_pt:)
        m  = SectionGrid.size_mult
        r  = SectionGrid::CIRCLE_R.mm * m
        bs = 3.mm * m
        draw_split_h_with_wedges(ents, [0, 0, 0], r, label_top, label_bot)
        line_start = line_offset_for(line_dir, r + 1.mm * m)
        SectionGrid.draw_line(ents, [line_start.x, line_start.y, 0], [end_pt.x, end_pt.y, 0], broken: broken)
        draw_bracket_at_line_end(ents, end_pt, bs, line_dir)
      end
      private_class_method :draw_ref_split_h_arrow_two_point

      # v5.74: two-point version of ref_h_arrow_single — same head geometry
      # as ref_split_h_arrow_two_point but no divider inside the circle
      # and a single centred label.
      def self.draw_ref_h_arrow_single_two_point(ents, label, broken, line_dir:, end_pt:)
        m  = SectionGrid.size_mult
        r  = SectionGrid::CIRCLE_R.mm * m
        bs = 3.mm * m
        draw_h_wedges_single(ents, [0, 0, 0], r, label)
        line_start = line_offset_for(line_dir, r + 1.mm * m)
        SectionGrid.draw_line(ents, [line_start.x, line_start.y, 0], [end_pt.x, end_pt.y, 0], broken: broken)
        draw_bracket_at_line_end(ents, end_pt, bs, line_dir)
      end
      private_class_method :draw_ref_h_arrow_single_two_point

      # ref_split_v_arrow: split-V circle at pt1, chain-dot to pt2 terminated
      # by a filled triangle facing the head.
      def self.draw_ref_split_v_arrow_two_point(ents, label_left, label_right, broken, line_dir:, end_pt:)
        m = SectionGrid.size_mult
        r = SectionGrid::CIRCLE_R.mm * m
        draw_split_circle(ents, [0, 0, 0], r, label_left, label_right, :vertical)
        line_start = line_offset_for(line_dir, r + 1.mm * m)
        SectionGrid.draw_line(ents, [line_start.x, line_start.y, 0], [end_pt.x, end_pt.y, 0], broken: broken)
        # Filled triangle at the line's far end, pointing back TOWARD the head
        back_dir = opposite_dir(line_dir)
        draw_filled_triangle(ents, end_pt, 2.mm * m, back_dir)
      end
      private_class_method :draw_ref_split_v_arrow_two_point

      def self.opposite_dir(dir)
        { up: :down, down: :up, left: :right, right: :left }[dir] || :down
      end
      private_class_method :opposite_dir

      # Small L-bracket at the far end of the line, opening AWAY from the
      # head (i.e., tick lines lie in the direction the line came from).
      def self.draw_bracket_at_line_end(ents, end_pt, bs, line_dir)
        case line_dir
        when :up
          # Line came from below; bracket opens down-right at end_pt
          ents.add_line([end_pt.x, end_pt.y, 0], [end_pt.x + bs, end_pt.y, 0])
          ents.add_line([end_pt.x, end_pt.y, 0], [end_pt.x, end_pt.y - bs, 0])
        when :down
          ents.add_line([end_pt.x, end_pt.y, 0], [end_pt.x + bs, end_pt.y, 0])
          ents.add_line([end_pt.x, end_pt.y, 0], [end_pt.x, end_pt.y + bs, 0])
        when :right
          ents.add_line([end_pt.x, end_pt.y, 0], [end_pt.x - bs, end_pt.y, 0])
          ents.add_line([end_pt.x, end_pt.y, 0], [end_pt.x, end_pt.y + bs, 0])
        when :left
          ents.add_line([end_pt.x, end_pt.y, 0], [end_pt.x + bs, end_pt.y, 0])
          ents.add_line([end_pt.x, end_pt.y, 0], [end_pt.x, end_pt.y + bs, 0])
        end
      end
      private_class_method :draw_bracket_at_line_end

      def self.draw_full_section_at(ents, label, broken, top, bot)
        m    = SectionGrid.size_mult
        r    = SectionGrid::CIRCLE_R.mm   * m
        head = SectionGrid::ARROW_HEAD.mm * m
        SectionGrid.draw_circle_label(ents, [top.x, top.y, 0], r, label)
        top_a  = top.y - r * 2
        bot_a  = bot.y + r * 2
        SectionGrid.draw_line(ents, [top.x, top_a - head, 0], [bot.x, bot_a + head, 0], broken: broken)
        pts_up = [
          Geom::Point3d.new(top.x - head / 2.0, top_a,        0),
          Geom::Point3d.new(top.x + head / 2.0, top_a,        0),
          Geom::Point3d.new(top.x,              top_a - head, 0)
        ]
        face1 = ents.add_face(pts_up); face1.material = 'black' if face1; face1.back_material = 'black' if face1
        pts_dn = [
          Geom::Point3d.new(bot.x - head / 2.0, bot_a,        0),
          Geom::Point3d.new(bot.x + head / 2.0, bot_a,        0),
          Geom::Point3d.new(bot.x,              bot_a + head, 0)
        ]
        face2 = ents.add_face(pts_dn); face2.material = 'black' if face2; face2.back_material = 'black' if face2
        SectionGrid.draw_circle_label(ents, [bot.x, bot.y, 0], r, label)
      end
      private_class_method :draw_full_section_at

      # Every section style uses two-click placement now: the user clicks the
      # HEAD position first and the LINE endpoint second. Dual-head styles
      # (see DUAL_HEAD_STYLES) also draw a mirrored marker at the second
      # click; single-head styles just extend a chain-dot line from the head.
      TWO_POINT_STYLES = %w[
        arrow_round_filled
        arrow_round_hollow
        arrow_diamond
        full_section
        elevation_callout
        circle_only
        section_horizontal
        section_bracket_round
        section_bracket_split_diamond
        ref_split_h_arrow
        ref_split_v_arrow
        ref_aa_directional
        side_arrow_dual
        side_arrow_bracket
      ].freeze

      DUAL_HEAD_STYLES = %w[
        full_section
        section_horizontal
        section_bracket_round
        section_bracket_split_diamond
        ref_aa_directional
        side_arrow_dual
        side_arrow_bracket
      ].freeze

      # Placement tool: activates when user needs to click a location
      class PlaceTool
        def initialize(style, label, broken, label2 = nil, dot_count = 1)
          @style     = style
          @label     = label
          @label2    = label2 || label
          @broken    = broken
          @dot_count = dot_count.to_i.clamp(1, 3)
          @ip        = Sketchup::InputPoint.new
          @first_pt  = nil
          @curr_pt   = nil       # cursor position for rubber-band preview
          @two_point = Sections::TWO_POINT_STYLES.include?(style)
        end

        def activate
          Sketchup.set_status_text(
            @two_point ? 'Click FIRST endpoint of section line (Esc to cancel)'
                       : "Click to place [#{@style}] '#{@label}' (Esc to cancel)"
          )
        end

        # Reset state so the preview overlay disappears if the user switches
        # tools mid-placement.
        def deactivate(view)
          @first_pt = nil
          @curr_pt  = nil
          view.invalidate rescue nil
        end

        def onMouseMove(_flags, x, y, view)
          @ip.pick(view, x, y)
          if @two_point && @first_pt
            @curr_pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)
          end
          view.invalidate
        end

        # SketchUp calls this every frame while the tool is active. We only
        # do work when a rubber-band preview is actually needed — so no
        # per-frame cost when the tool is idle or not the active tool.
        def draw(view)
          return unless @two_point && @first_pt && @curr_pt
          view.line_width    = 1
          view.line_stipple  = '-'
          view.drawing_color = Sketchup::Color.new(120, 120, 220)
          view.draw(GL_LINES, @first_pt, @curr_pt)
        end

        def onLButtonDown(_flags, x, y, view)
          @ip.pick(view, x, y)
          pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)

          if @two_point && @first_pt.nil?
            @first_pt = pt
            @curr_pt  = pt
            Sketchup.set_status_text('Click SECOND endpoint to finish section line')
            return
          end

          if @two_point
            Sections.build_two_point(@style, @label, @broken, @first_pt, pt, @label2, @dot_count)
          else
            Sections.build(@style, @label, @broken, pt, view, @label2, @dot_count)
          end
          UI.start_timer(0.0, false) { Sketchup.active_model.select_tool(nil) }
        end

        def onKeyDown(key, _r, _f, _v)
          Sketchup.active_model.select_tool(nil) if key == 27
        end
      end
    end

    # =========================================================================
    # GRID GENERATOR
    # =========================================================================
    module Grid
      def self.start_placement(cfg_json)
        require 'json'
        cfg = JSON.parse(cfg_json)
        Sketchup.set_status_text('Click to place top-left corner of grid (Esc to cancel)')
        Sketchup.active_model.select_tool(PlaceTool.new(cfg))
      end

      def self.build(cfg, origin)
        model = Sketchup.active_model
        model.start_operation('Place Grid', true)
        # Scale the whole grid to match the current view so a grid dropped
        # on a metre-scale scaffold isn't a paper-mm speck. User's
        # hspace/vspace are still respected — we scale them by the same
        # multiplier as the intersection markers, so proportions stay
        # correct on paper too (mult = 1.0 inside a paper frame).
        paper_mult = SketchDraw::State.paper_scale_multiplier_at(model, origin)
        SectionGrid.with_size_mult(paper_mult) do
        begin
          grp = model.active_entities.add_group
          grp.name = "SketchDraw_Grid_#{cfg['cols']}x#{cfg['rows']}"
          grp.set_attribute(SectionGrid::ATTR_NS, 'type', 'grid_layout')

          cols   = cfg['cols'].to_i
          rows   = cfg['rows'].to_i
          line   = cfg['line']
          marker = cfg['marker']
          broken = (line == 'broken')
          # Marker + label size scale from D's feedback: "how do i make the
          # letters bigger / smaller". Default preserves the pre-v5.70 look.
          text_scale = case cfg['text_size'].to_s
                       when 'small'  then 0.7
                       when 'large'  then 1.5
                       when 'xlarge' then 2.2
                       else               1.0   # medium / unspecified
                       end

          # Build spacing arrays
          if cfg['advanced'] && cfg['col_gaps'].is_a?(Array) && cfg['col_gaps'].length >= cols - 1
            col_gaps = cfg['col_gaps'][0, cols - 1].map(&:to_f)
          else
            hs = cfg['hspace'].to_f
            col_gaps = Array.new(cols - 1, hs)
          end
          if cfg['advanced'] && cfg['row_gaps'].is_a?(Array) && cfg['row_gaps'].length >= rows - 1
            row_gaps = cfg['row_gaps'][0, rows - 1].map(&:to_f)
          else
            vs = cfg['vspace'].to_f
            row_gaps = Array.new(rows - 1, vs)
          end

          # Cumulative x positions for each column
          x_positions = [0.0]
          col_gaps.each { |g| x_positions << x_positions.last + g }
          # Cumulative y positions for each row (going DOWN)
          y_positions = [0.0]
          row_gaps.each { |g| y_positions << y_positions.last - g }

          # v5.71: split multiplier usage between POSITIONS and MARKERS.
          # • Positions (line spacing) = actual model mm (no multiplier).
          #   User enters 2000 → gets 2 m cells, regardless of drawing
          #   scale. D expected this and treated the previous behaviour
          #   as a bug ("2M cells appear bigger than my 10M drawing").
          # • Markers (circles, labels, margin) = still scaled by
          #   paper_mult so they look the right size on paper at any
          #   drawing scale — otherwise a 40mm marker on a 1:50 scaffold
          #   would be an invisible speck.
          m       = paper_mult
          margin  = 8.mm * m
          top_y   = 0.0 + margin
          bot_y   = y_positions.last.mm - margin
          left_x  = -margin
          right_x = x_positions.last.mm + margin
          r_mark  = SectionGrid::CIRCLE_R.mm * m * text_scale

          ents = grp.entities

          # ── Draw vertical column lines & top+bottom markers ─────────
          x_positions.each_with_index do |x, i|
            xi = x.mm
            SectionGrid.draw_line(ents, [xi, top_y, 0], [xi, bot_y, 0], broken: broken)

            letter = (i < 26 ? ('A'.ord + i).chr : "A#{('A'.ord + (i-26)).chr}")
            SectionGrid.draw_grid_marker(ents, [xi, top_y + r_mark, 0],
                                         letter, shape: marker.to_sym, scale: text_scale)
            SectionGrid.draw_grid_marker(ents, [xi, bot_y - r_mark, 0],
                                         letter, shape: marker.to_sym, scale: text_scale)
          end

          # ── Draw horizontal row lines & left+right markers ──────────
          y_positions.each_with_index do |y, i|
            yi = y.mm
            SectionGrid.draw_line(ents, [left_x, yi, 0], [right_x, yi, 0], broken: broken)

            number = (i + 1).to_s
            SectionGrid.draw_grid_marker(ents, [left_x - r_mark, yi, 0],
                                         number, shape: marker.to_sym, scale: text_scale)
            SectionGrid.draw_grid_marker(ents, [right_x + r_mark, yi, 0],
                                         number, shape: marker.to_sym, scale: text_scale)
          end

          # Offset the whole group so the CLICK POINT lands at the actual
          # top-left grid intersection (column A × row 1), and the top-left
          # markers sit above-and-left of it. Previously the click was placed
          # at column A × row 1 with no compensation, so users had to click
          # noticeably inside the paper margin.
          marker_pad = margin + SectionGrid::CIRCLE_R.mm * 2 + 2.mm
          grp.transformation = Geom::Transformation.translation(
            Geom::Vector3d.new(origin.x + marker_pad, origin.y - marker_pad, 0)
          )
          model.commit_operation
        rescue => e
          model.abort_operation rescue nil
          UI.messagebox("Grid placement failed: #{e.class}: #{e.message}")
        end
        end
      end

      class PlaceTool
        def initialize(cfg)
          @cfg = cfg
          @ip  = Sketchup::InputPoint.new
        end

        def activate
          Sketchup.set_status_text("Click to place top-left corner of the #{@cfg['cols']}x#{@cfg['rows']} grid")
        end

        def onMouseMove(_flags, x, y, view)
          @ip.pick(view, x, y)
          view.invalidate
        end

        def onLButtonDown(_flags, x, y, view)
          @ip.pick(view, x, y)
          pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)
          Grid.build(@cfg, pt)
          UI.start_timer(0.0, false) { Sketchup.active_model.select_tool(nil) }
        end

        def onKeyDown(key, _r, _f, _v)
          Sketchup.active_model.select_tool(nil) if key == 27
        end
      end
    end

    # =========================================================================
    # LEVEL MARKERS
    # =========================================================================
    module Levels
      def self.start_placement(style, elev)
        Sketchup.set_status_text('Click to place level marker (Esc to cancel)')
        Sketchup.active_model.select_tool(PlaceTool.new(style, elev))
      end

      def self.build(style, elev, pt)
        model = Sketchup.active_model
        model.start_operation('Place Level Marker', true)
        # Scale geometry to match the current view, so a level marker
        # dropped on a metre-scale scaffold isn't a paper-mm speck. Same
        # pattern the Text/Arrow tools already use.
        paper_mult = SketchDraw::State.paper_scale_multiplier_at(model, pt)
        SectionGrid.with_size_mult(paper_mult) do
        begin
          grp = model.active_entities.add_group
          grp.name = "SketchDraw_Level_#{style}"
          grp.set_attribute(SectionGrid::ATTR_NS, 'type', 'level_marker')

          case style
          when 'ffl'           then build_split_circle(grp.entities, 'FFL', elev)
          when 'ssl'           then build_split_circle(grp.entities, 'SSL', elev)
          when 'datum'         then build_split_circle(grp.entities, 'DATUM', elev)
          when 'parapet'       then build_parapet(grp.entities, elev)
          when 'cross'         then build_cross(grp.entities, 'FFL', elev)
          when 'ffl_ssl_split' then build_ffl_ssl_split(grp.entities, elev)
          end

          grp.transformation = Geom::Transformation.translation(
            Geom::Vector3d.new(pt.x, pt.y, 0)
          )
          model.commit_operation
        rescue => e
          model.abort_operation rescue nil
          UI.messagebox("Level marker failed: #{e.message}")
        end
        end
      end

      # Split circle: circle with a horizontal and vertical line, plus label + elevation
      def self.build_split_circle(ents, label, elev)
        m = SectionGrid.size_mult
        r = SectionGrid::CIRCLE_R.mm * m
        # Circle outline
        circle = ents.add_circle(Geom::Point3d.new(0, 0, 0),
                                 Geom::Vector3d.new(0, 0, 1), r, 24)
        # Cross lines
        ents.add_line(Geom::Point3d.new(-r, 0, 0), Geom::Point3d.new(r, 0, 0))
        ents.add_line(Geom::Point3d.new(0, -r, 0), Geom::Point3d.new(0, r, 0))
        # Label inside top-left quadrant
        ents.add_text(label, Geom::Point3d.new(-r*0.9, r*0.2, 0))
        # Elevation value to the right of the marker
        ents.add_text(elev, Geom::Point3d.new(r + 1.mm * m, -1.mm * m, 0))
      end
      private_class_method :build_split_circle

      # Top of Parapet: horizontal chain-dot line with a downward triangle pointer + elev
      def self.build_parapet(ents, elev)
        m    = SectionGrid.size_mult
        head = SectionGrid::ARROW_HEAD.mm * m
        # Horizontal chain-dot reference line
        SectionGrid.draw_line(ents, [-25.mm * m, 0, 0], [25.mm * m, 0, 0], broken: true)
        # Downward triangle pointing to the line
        pts = [
          Geom::Point3d.new(-head/2.0, head, 0),
          Geom::Point3d.new( head/2.0, head, 0),
          Geom::Point3d.new(0,          0,   0)
        ]
        face = ents.add_face(pts); face.material = 'black' if face; face.back_material = 'black' if face
        # Elevation text
        ents.add_text(elev, Geom::Point3d.new(head/2.0 + 2.mm * m, -1.mm * m, 0))
        # Label above triangle
        ents.add_text('TOP OF PARAPET', Geom::Point3d.new(-25.mm * m, head + 3.mm * m, 0))
      end
      private_class_method :build_parapet

      # Simple cross with label and elevation
      def self.build_cross(ents, label, elev)
        m = SectionGrid.size_mult
        s = 5.mm * m
        ents.add_line(Geom::Point3d.new(-s, 0, 0), Geom::Point3d.new(s, 0, 0))
        ents.add_line(Geom::Point3d.new(0, -s, 0), Geom::Point3d.new(0, s, 0))
        ents.add_text(label, Geom::Point3d.new(s + 1.mm * m, 1.mm * m, 0))
        ents.add_text(elev,  Geom::Point3d.new(s + 1.mm * m, -4.mm * m, 0))
      end
      private_class_method :build_cross

      # Reference-sheet FFL/SSL split circle: one circle, horizontal divider,
      # "FFL" in the top half, "SSL" in the bottom half, elevation to the right.
      def self.build_ffl_ssl_split(ents, elev)
        m = SectionGrid.size_mult
        r = SectionGrid::CIRCLE_R.mm * m
        c = Geom::Point3d.new(0, 0, 0)
        ents.add_circle(c, Geom::Vector3d.new(0, 0, 1), r, 24)
        ents.add_line([c.x - r, c.y, 0], [c.x + r, c.y, 0])
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new(c.x, c.y + r * 0.5, 0), r * 0.6, 'FFL')
        SectionGrid.draw_centered_label(ents, Geom::Point3d.new(c.x, c.y - r * 0.5, 0), r * 0.6, 'SSL')
        ents.add_text(elev, Geom::Point3d.new(r + 2.mm * m, -2.mm * m, 0))
      end
      private_class_method :build_ffl_ssl_split

      class PlaceTool
        def initialize(style, elev)
          @style = style
          @elev  = elev
          @ip    = Sketchup::InputPoint.new
        end

        def activate
          Sketchup.set_status_text("Click to place [#{@style}] '#{@elev}'")
        end

        def onMouseMove(_flags, x, y, view)
          @ip.pick(view, x, y)
          view.invalidate
        end

        def onLButtonDown(_flags, x, y, view)
          @ip.pick(view, x, y)
          pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)
          Levels.build(@style, @elev, pt)
          UI.start_timer(0.0, false) { Sketchup.active_model.select_tool(nil) }
        end

        def onKeyDown(key, _r, _f, _v)
          Sketchup.active_model.select_tool(nil) if key == 27
        end
      end
    end

    # =========================================================================
    # SHARED DRAWING HELPERS
    # =========================================================================

    # Draw a line, either solid or as chain-dot (dash + dot + dash pattern)
    # by breaking it into segments. This gives a visible dashed appearance
    # inside SketchUp; the PDF exporter's own dash logic doesn't apply here
    # because these are individual short edges rather than styled long ones.
    def self.draw_line(ents, p1, p2, broken: false)
      pt1 = Geom::Point3d.new(*p1)
      pt2 = Geom::Point3d.new(*p2)
      if broken
        draw_chain_dot_native(ents, pt1, pt2)
      else
        ents.add_line(pt1, pt2)
      end
    end

    # v5.70: replaces manual dash-segment generation with SU's native
    # line_style rendering. Puts the edge on a shared `SKD_Grid_ChainDot`
    # layer whose line_style is set to "Dash dot" — SketchUp then handles
    # the dash pattern at render time for free.
    #
    # Why this rewrite: the old `draw_chain_dot` walked the line in
    # ~10mm pattern cycles and called `add_line` for each dash + dot. A
    # 20m grid line at paper-scale mult=1 spawned ~3,800 add_line calls;
    # a 10×10 grid at 2m spacing (D's real-world test) meant ~76,000
    # add_line calls → SU frozen for 2-3 minutes on commit_operation.
    # Native line_style renders the same visual with one edge per line.
    def self.draw_chain_dot_native(ents, pt1, pt2)
      edge = ents.add_line(pt1, pt2)
      return unless edge
      model = Sketchup.active_model
      return unless model.respond_to?(:line_styles) && model.respond_to?(:layers)

      layer_name = 'SKD_Grid_ChainDot'
      layer = model.layers[layer_name] || model.layers.add(layer_name)
      begin
        style = model.line_styles['Dash dot']
        layer.line_style = style if layer.respond_to?(:line_style=) && style
      rescue
        # If SU version doesn't support line_style API, edge stays solid
        # on this layer — still 76,000× faster than the old approach.
      end
      edge.layer = layer if edge.respond_to?(:layer=)
    end

    def self.draw_chain_dot(ents, pt1, pt2)
      total = pt1.distance(pt2)
      return if total < 0.001
      vec = (pt2 - pt1); vec.length = 1
      # Scale the chain-dot pattern with the current size_mult so a big
      # world-scale line doesn't get chopped into thousands of tiny paper-mm
      # dashes. Without this, a 10m grid line at paper mult=50 spawns ~800
      # add_line calls and freezes SketchUp for seconds. With the multiplier
      # the same line has ~15-20 pattern cycles and is instant.
      m    = size_mult
      dash = CHAIN_DASH_MM.mm * m
      gap  = CHAIN_GAP_MM.mm  * m
      dot  = CHAIN_DOT_MM.mm  * m
      n_dots = chain_dot_count   # 1, 2, or 3 dots between dashes

      # Pattern: dash - gap - (dot - gap) × N - (repeat)
      pos = 0.0
      while pos < total
        # ── dash segment ───────────────────────────────────────
        d_end = [pos + dash, total].min
        if d_end - pos > 0.001
          ents.add_line(pt1.offset(vec, pos), pt1.offset(vec, d_end))
        end
        pos = d_end + gap

        # ── N dot segments between this dash and the next ────
        i = 0
        while i < n_dots && pos < total
          dot_end = [pos + dot, total].min
          if dot_end - pos > 0.001
            ents.add_line(pt1.offset(vec, pos), pt1.offset(vec, dot_end))
          end
          pos = dot_end + gap
          i += 1
        end
      end
    end

    # Draw a circle with a letter/number inside
    def self.draw_circle_label(ents, center, r, label)
      c = Geom::Point3d.new(*center)
      ents.add_circle(c, Geom::Vector3d.new(0, 0, 1), r, 24)
      draw_centered_label(ents, c, r, label)
    end

    # Draw a diamond (rotated square) with a letter inside
    def self.draw_diamond_label(ents, center, r, label)
      c = Geom::Point3d.new(*center)
      pts = [
        Geom::Point3d.new(c.x,     c.y + r, 0),
        Geom::Point3d.new(c.x + r, c.y,     0),
        Geom::Point3d.new(c.x,     c.y - r, 0),
        Geom::Point3d.new(c.x - r, c.y,     0)
      ]
      pts.each_with_index { |p, i| ents.add_line(p, pts[(i+1) % 4]) }
      draw_centered_label(ents, c, r, label)
    end

    # Create a filled 2D vector-text glyph inside a sub-group, then translate
    # the sub-group so its bounding-box centre sits exactly on `center`.
    # This gives real geometric centring — `add_text` uses screen-fixed
    # pixels and can't be centred precisely inside a shape at model scale.
    def self.draw_centered_label(ents, center, r, label)
      height = r * 1.1   # letter height ≈ 55% of circle diameter — fits legibly
      grp = ents.add_group
      grp.entities.add_3d_text(
        label.to_s,
        TextAlignCenter,
        'Arial',
        true,     # bold
        false,    # italic
        height,
        0.0,      # tolerance
        0.0,      # z
        true,     # filled (so PDF export renders it as a solid glyph)
        0.0       # extrusion (flat)
      )
      b = grp.bounds
      if b.width > 0 && b.height > 0
        offset = Geom::Vector3d.new(center.x - b.center.x, center.y - b.center.y, 0)
        grp.transformation = Geom::Transformation.translation(offset)
      else
        # Fallback: add_3d_text refused the string (very rare). Use plain
        # note text with approximate offset so the label is still visible.
        grp.erase! rescue nil
        tp = Geom::Point3d.new(center.x - r * 0.35, center.y - r * 0.5, 0)
        ents.add_text(label.to_s, tp)
      end
    rescue
      # Never let a text failure abort the grid build.
      nil
    end

    # Draw a grid line end marker (round or diamond) with a label
    # `scale` — extra multiplier for the marker radius and its label
    # (defaults to 1.0). Used by the Grid feature to expose a text-size
    # setting to the user without changing every other caller.
    def self.draw_grid_marker(ents, center, label, shape: :round, scale: 1.0)
      r = CIRCLE_R.mm * size_mult * scale
      case shape
      when :diamond
        draw_diamond_label(ents, center, r, label)
      when :split_v
        draw_split_v_label(ents, center, r, label)
      when :bracket
        draw_bracket_marker(ents, center, r)
      else
        draw_circle_label(ents, center, r, label)
      end
    end

    # Reference-sheet split-vertical circle: circle with a vertical divider
    # and the same label mirrored either side of the divider.
    def self.draw_split_v_label(ents, center, r, label)
      c = Geom::Point3d.new(*center)
      ents.add_circle(c, Geom::Vector3d.new(0, 0, 1), r, 24)
      ents.add_line([c.x, c.y - r, 0], [c.x, c.y + r, 0])
      draw_centered_label(ents, Geom::Point3d.new(c.x - r * 0.5, c.y, 0), r * 0.55, label)
      draw_centered_label(ents, Geom::Point3d.new(c.x + r * 0.5, c.y, 0), r * 0.55, label)
    end

    # Reference-sheet bracket-only marker: a small L-shaped tick, no label.
    def self.draw_bracket_marker(ents, center, r)
      c = Geom::Point3d.new(*center)
      s = r
      ents.add_line([c.x - s, c.y - s, 0], [c.x + s, c.y - s, 0])
      ents.add_line([c.x + s, c.y - s, 0], [c.x + s, c.y + s, 0])
    end
  end
end
