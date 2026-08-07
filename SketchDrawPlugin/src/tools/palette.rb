require 'fileutils'
require 'json'

module SketchDraw
  # ============================================================================
  # Feature A - Drag and Drop Palette (with folder tree)
  # ============================================================================
  # A dockable panel that stores a personal library of reusable shapes.
  #
  # Storage layout on disk:
  #   <userdata>/SketchDrawPlugin/palette/
  #     |- clamps/
  #     |    |- standard/
  #     |    |    |- clamp_01.skp
  #     |    |    |- clamp_01.png    <- thumbnail
  #     |    |- ...
  #     |- beams/
  #     |    |- ...
  #
  # Because items live on disk, having many items does NOT affect SketchUp
  # performance. Only the item the user actually places is loaded into the
  # active model.
  # ============================================================================
  module Palette
    ATTR_NS = SketchDraw::PLUGIN_ID
    THUMB_PX = 128

    @dialog = nil

    # ── Data directory (per-user) ───────────────────────────────────────
    def self.data_dir
      base = ENV['APPDATA'] || ENV['HOME'] || Dir.tmpdir
      dir  = File.join(base, 'SketchDrawPlugin', 'palette')
      FileUtils.mkdir_p(dir) unless File.exist?(dir)
      dir
    end

    # Convert a slash-separated relative folder path to absolute
    def self.abs_path(rel)
      rel = rel.to_s.gsub(/[\\\/]+/, '/').gsub(/^\/+|\/+$/, '')
      File.join(data_dir, rel)
    end

    # Reverse: absolute path back to relative for the palette
    def self.rel_path(abs)
      root = data_dir
      abs.start_with?(root) ? abs[root.length..-1].sub(/^\//, '') : abs
    end

    # ── Panel entry point ───────────────────────────────────────────────
    def self.open_panel
      return unless SketchDraw.version_ok?

      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title:    'SketchDraw Palette',
        preferences_key: 'SketchDraw_Palette_v1',
        width:  760,
        height: 520,
        min_width:  520,
        min_height: 340,
        style:  UI::HtmlDialog::STYLE_UTILITY,
        resizable: true
      )
      @dialog.set_html(panel_html)

      @dialog.add_action_callback('load_tree')     { |_| push_tree }
      @dialog.add_action_callback('load_folder')   { |_, rel| push_folder(rel) }
      @dialog.add_action_callback('save_selection'){ |_, rel| save_current_selection(rel) }
      @dialog.add_action_callback('place_item')    { |_, item_rel| place_item(item_rel) }
      @dialog.add_action_callback('create_folder') { |_, parent_rel, name| create_folder(parent_rel, name) }
      @dialog.add_action_callback('delete_folder') { |_, rel| delete_folder(rel) }
      @dialog.add_action_callback('delete_item')   { |_, item_rel| delete_item(item_rel) }
      @dialog.add_action_callback('open_data_dir') { |_| open_data_dir }

      @dialog.show
    end

    # Push the whole folder tree to the panel
    def self.push_tree
      tree = build_folder_tree(data_dir, '')
      return unless @dialog
      @dialog.execute_script("receiveTree(#{tree.to_json})")
    end

    # Recursive folder scan (only directories)
    def self.build_folder_tree(abs, rel)
      node = { name: rel.empty? ? 'All' : File.basename(rel), path: rel, children: [] }
      return node unless File.directory?(abs)
      Dir.children(abs).sort.each do |entry|
        full = File.join(abs, entry)
        next unless File.directory?(full)
        child_rel = rel.empty? ? entry : "#{rel}/#{entry}"
        node[:children] << build_folder_tree(full, child_rel)
      end
      node
    end

    # Push the item list for the selected folder
    def self.push_folder(rel)
      abs = abs_path(rel)
      items = []
      if File.directory?(abs)
        Dir.children(abs).sort.each do |entry|
          next unless entry.downcase.end_with?('.skp')
          skp_full = File.join(abs, entry)
          base     = File.basename(entry, '.skp')
          png_full = File.join(abs, "#{base}.png")
          items << {
            name:     base,
            item_rel: rel.empty? ? "#{base}.skp" : "#{rel}/#{base}.skp",
            thumb:    File.exist?(png_full) ? file_to_data_url(png_full) : nil
          }
        end
      end
      return unless @dialog
      @dialog.execute_script("receiveFolder(#{ { rel: rel, items: items }.to_json })")
    end

    # PNG file -> data URL for inline HTML display
    def self.file_to_data_url(path)
      data = File.binread(path)
      require 'base64'
      "data:image/png;base64,#{Base64.strict_encode64(data)}"
    rescue
      nil
    end

    # ── Save Selection ──────────────────────────────────────────────────
    def self.save_current_selection(folder_rel)
      model = Sketchup.active_model
      sel   = model.selection.to_a
      if sel.empty?
        UI.messagebox('Select one or more objects in the SketchUp drawing first, then click Save Selection.')
        return
      end

      # Ask for a name via a simple inputbox
      prompts  = ['Item name:']
      defaults = ["item_#{Time.now.to_i}"]
      result   = UI.inputbox(prompts, defaults, 'Save to Palette')
      return unless result
      name = result[0].to_s.strip.gsub(/[^A-Za-z0-9 _-]/, '_')
      return if name.empty?

      folder_abs = abs_path(folder_rel)
      FileUtils.mkdir_p(folder_abs)

      # Unique filename
      base = name
      skp_path = File.join(folder_abs, "#{base}.skp")
      i = 1
      while File.exist?(skp_path)
        skp_path = File.join(folder_abs, "#{base}_#{i}.skp")
        i += 1
      end
      final_base = File.basename(skp_path, '.skp')
      png_path   = File.join(folder_abs, "#{final_base}.png")

      # Capture the selection into a temporary group, save its definition to .skp
      model.start_operation('Save to Palette', true)
      begin
        # Wrap the selection in a group so we get a clean bounding box + definition
        grp = model.active_entities.add_group(sel)
        grp.name = final_base

        # Take viewport screenshot as thumbnail (zoomed to the group bounds)
        write_thumbnail(model, grp, png_path)

        # Save the group's definition to .skp
        defn = grp.definition
        defn.save_as(skp_path)

        # Undo the temporary grouping so the user's drawing is unchanged
        model.abort_operation
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("Save to Palette failed: #{e.class}: #{e.message}")
        return
      end

      # Refresh the panel view
      push_tree
      push_folder(folder_rel)
    end

    # Capture a small PNG of the current viewport zoomed to the given entity
    def self.write_thumbnail(model, ent, png_path)
      view = model.active_view

      # Save current camera to restore afterwards
      cam = view.camera
      saved = { eye: cam.eye.clone, target: cam.target.clone,
                up: cam.up.clone, persp: cam.perspective? }

      begin
        cam.perspective = false
        view.zoom(ent)
        view.write_image(png_path, THUMB_PX, THUMB_PX, true, 0.9)
      ensure
        cam.set(saved[:eye], saved[:target], saved[:up])
        cam.perspective = saved[:persp]
      end
    rescue => e
      puts "SketchDraw Palette write_thumbnail: #{e.message}"
    end
    private_class_method :write_thumbnail

    # ── Place an item ───────────────────────────────────────────────────
    def self.place_item(item_rel)
      full = abs_path(item_rel)
      unless File.exist?(full)
        UI.messagebox("Item not found:\n#{full}")
        return
      end
      model = Sketchup.active_model
      defn  = model.definitions.load(full)
      model.select_tool(PlaceTool.new(defn))
    end

    class PlaceTool
      def initialize(defn)
        @defn = defn
        @ip   = Sketchup::InputPoint.new
      end

      def activate
        Sketchup.set_status_text("Click to place '#{@defn.name}' (Esc to cancel)")
      end

      def onMouseMove(_flags, x, y, view)
        @ip.pick(view, x, y)
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        @ip.pick(view, x, y)
        pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)
        model = Sketchup.active_model
        model.start_operation('Place Palette Item', true)
        inst = model.active_entities.add_instance(@defn, Geom::Transformation.new(pt))
        model.commit_operation
        model.selection.clear
        model.selection.add(inst)
        UI.start_timer(0.0, false) { Sketchup.active_model.select_tool(nil) }
      end

      def onKeyDown(key, _r, _f, _v)
        Sketchup.active_model.select_tool(nil) if key == 27
      end
    end

    # ── Folder CRUD ─────────────────────────────────────────────────────
    def self.create_folder(parent_rel, name)
      name = name.to_s.strip.gsub(/[^A-Za-z0-9 _-]/, '_')
      return if name.empty?
      abs = abs_path(parent_rel.to_s)
      new_abs = File.join(abs, name)
      FileUtils.mkdir_p(new_abs)
      push_tree
    end

    def self.delete_folder(rel)
      return if rel.to_s.strip.empty?
      abs = abs_path(rel)
      return unless File.directory?(abs)
      response = UI.messagebox("Delete folder and everything inside?\n\n#{rel}", MB_YESNO)
      return unless response == IDYES
      FileUtils.rm_rf(abs)
      push_tree
    end

    def self.delete_item(item_rel)
      abs = abs_path(item_rel)
      return unless File.file?(abs)
      response = UI.messagebox("Delete this item?\n\n#{item_rel}", MB_YESNO)
      return unless response == IDYES
      File.delete(abs) rescue nil
      png = abs.sub(/\.skp$/i, '.png')
      File.delete(png) rescue nil
      parent_rel = File.dirname(item_rel)
      parent_rel = '' if parent_rel == '.' || parent_rel == '/'
      push_folder(parent_rel)
    end

    # Open the palette folder in the OS file explorer
    def self.open_data_dir
      UI.openURL("file:///#{data_dir.tr('\\', '/')}")
    end

    # ============================================================================
    # PANEL HTML
    # ============================================================================
    def self.panel_html
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          html, body { height: 100%; font-family: Arial, sans-serif;
                       background: #2b2b2b; color: #ddd; overflow: hidden; }
          .wrap { display: flex; height: 100%; }
          .left {
            width: 240px; min-width: 180px;
            background: #232323;
            border-right: 1px solid #444;
            display: flex; flex-direction: column;
          }
          .left-header {
            padding: 8px 10px;
            font-size: 12px; font-weight: bold;
            color: #eee;
            border-bottom: 1px solid #444;
            display: flex; justify-content: space-between; align-items: center;
          }
          .left-header button {
            font-size: 11px; padding: 3px 8px;
            background: #0078D4; color: #fff;
            border: none; border-radius: 2px; cursor: pointer;
          }
          .left-header button.mini {
            background: #444; padding: 3px 6px; margin-left: 4px;
          }
          .tree {
            flex: 1; overflow-y: auto;
            padding: 6px 4px;
            font-size: 12px;
          }
          .node {
            padding: 3px 6px 3px 6px;
            cursor: pointer;
            border-radius: 2px;
            display: flex; align-items: center; gap: 6px;
            white-space: nowrap;
          }
          .node:hover { background: #383838; }
          .node.active { background: #0078D4; color: #fff; }
          .node .caret { width: 8px; font-size: 9px; color: #aaa; }
          .node .icon { color: #F0C36D; }
          .children { padding-left: 14px; }

          .right {
            flex: 1;
            display: flex; flex-direction: column;
            background: #2b2b2b;
          }
          .right-header {
            padding: 10px 12px;
            display: flex; justify-content: space-between; align-items: center;
            border-bottom: 1px solid #444;
          }
          .breadcrumb { font-size: 13px; color: #ccc; font-weight: bold; }
          .actions button {
            font-size: 11px; padding: 6px 12px;
            background: #4CAF50; color: #fff;
            border: none; border-radius: 2px; cursor: pointer;
            font-weight: bold; margin-left: 6px;
          }
          .actions button.folder { background: #607D8B; }
          .actions button.opendir { background: #455A64; }

          .grid {
            flex: 1; overflow-y: auto;
            padding: 10px;
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
            gap: 10px;
            align-content: start;
          }
          .empty {
            grid-column: 1 / -1;
            text-align: center; padding: 40px 20px;
            color: #888; font-size: 13px; font-style: italic;
          }
          .card {
            background: #3a3a3a;
            border: 1px solid #555;
            border-radius: 3px;
            padding: 6px;
            display: flex; flex-direction: column; align-items: center;
            gap: 5px;
            cursor: pointer;
            transition: background .1s;
            position: relative;
          }
          .card:hover { background: #4a4a4a; }
          .card .thumb {
            width: 100%; height: 96px;
            background: #fff;
            display: flex; align-items: center; justify-content: center;
            border-radius: 2px;
            overflow: hidden;
          }
          .card .thumb img { max-width: 100%; max-height: 100%; }
          .card .label {
            font-size: 11px; color: #eee;
            text-align: center;
            width: 100%;
            overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
          }
          .card .del {
            position: absolute; top: 3px; right: 3px;
            background: rgba(200, 0, 0, 0.85);
            color: #fff;
            font-size: 10px;
            padding: 2px 6px;
            border-radius: 2px;
            display: none;
            cursor: pointer;
          }
          .card:hover .del { display: block; }
        </style>
        </head>
        <body>
          <div class="wrap">

            <!-- LEFT: folder tree -->
            <div class="left">
              <div class="left-header">
                <span>Categories</span>
                <span>
                  <button class="mini" onclick="newFolder()">+ Folder</button>
                </span>
              </div>
              <div class="tree" id="tree">Loading...</div>
            </div>

            <!-- RIGHT: items grid -->
            <div class="right">
              <div class="right-header">
                <div class="breadcrumb" id="breadcrumb">All</div>
                <div class="actions">
                  <button class="opendir" onclick="sketchup.open_data_dir()">Open Folder</button>
                  <button class="folder" onclick="deleteFolder()">Delete Folder</button>
                  <button onclick="saveSelection()">+ Save Selection</button>
                </div>
              </div>
              <div class="grid" id="grid">
                <div class="empty">Pick a folder on the left.</div>
              </div>
            </div>

          </div>

        <script>
          var currentFolder = '';
          var treeData = null;

          function receiveTree(data) {
            treeData = data;
            renderTree();
          }

          function renderTree() {
            var box = document.getElementById('tree');
            box.innerHTML = '';
            box.appendChild(renderNode(treeData, 0, ''));
          }

          function renderNode(node, depth, parentRel) {
            var wrap = document.createElement('div');

            var row = document.createElement('div');
            row.className = 'node' + (currentFolder === node.path ? ' active' : '');
            var caret = node.children.length > 0 ? '\\u25BE' : '';
            row.innerHTML = '<span class="caret">' + caret + '</span><span class="icon">\\uD83D\\uDCC1</span>' + node.name;
            row.onclick = function(e) {
              e.stopPropagation();
              currentFolder = node.path;
              renderTree();
              sketchup.load_folder(node.path);
            };
            wrap.appendChild(row);

            if (node.children.length > 0) {
              var kids = document.createElement('div');
              kids.className = 'children';
              node.children.forEach(function(child) {
                kids.appendChild(renderNode(child, depth+1, node.path));
              });
              wrap.appendChild(kids);
            }
            return wrap;
          }

          function receiveFolder(data) {
            document.getElementById('breadcrumb').textContent =
              data.rel === '' ? 'All' : data.rel;
            var grid = document.getElementById('grid');
            grid.innerHTML = '';
            if (!data.items || data.items.length === 0) {
              grid.innerHTML = '<div class="empty">No items in this folder yet. Select something in SketchUp and click Save Selection.</div>';
              return;
            }
            data.items.forEach(function(it) {
              var c = document.createElement('div');
              c.className = 'card';
              var thumb = it.thumb ? '<img src="' + it.thumb + '">' : '<div style="color:#888;font-size:10px">no preview</div>';
              c.innerHTML =
                '<div class="thumb">' + thumb + '</div>' +
                '<div class="label" title="' + it.name + '">' + it.name + '</div>' +
                '<div class="del">x</div>';
              c.onclick = function(e) {
                if (e.target.classList.contains('del')) {
                  sketchup.delete_item(it.item_rel);
                } else {
                  sketchup.place_item(it.item_rel);
                }
              };
              grid.appendChild(c);
            });
          }

          function saveSelection() {
            sketchup.save_selection(currentFolder);
          }

          function newFolder() {
            var name = prompt('New folder name (inside "' + (currentFolder || 'All') + '"):');
            if (!name) return;
            sketchup.create_folder(currentFolder, name);
          }

          function deleteFolder() {
            if (!currentFolder) { alert('Cannot delete the root folder.'); return; }
            sketchup.delete_folder(currentFolder);
            currentFolder = '';
            sketchup.load_folder('');
          }

          // Initial load
          sketchup.load_tree();
          sketchup.load_folder('');
        </script>
        </body>
        </html>
      HTML
    end
  end
end
