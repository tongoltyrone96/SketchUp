module SketchDraw
  module PaperFrame
    SIZES = {
      'A0' => [1189, 841],
      'A1' => [841,  594],
      'A2' => [594,  420],
      'A3' => [420,  297],
      'A4' => [297,  210]
    }.freeze

    ATTR_NS   = SketchDraw::PLUGIN_ID
    FRAME_TAG = 'paper_frame'.freeze

    # Inner-margin constants (mm) — uniform 10 mm on all four sides
    MARGIN_LEFT  = 10.0
    MARGIN_OTHER = 10.0
    TB_HEIGHT    = 25.0

    TB_COL_SPLITS = [0.28, 0.55, 0.73, 0.83].freeze

    TB_FIELDS = [
      { key: 'project_name',  label: 'PROJECT',   x0: 0.0,  x1: 0.28 },
      { key: 'drawing_title', label: 'TITLE',      x0: 0.28, x1: 0.55 },
      { key: 'drawn_by',      label: 'DRAWN BY',   x0: 0.55, x1: 0.73 },
      { key: 'date',          label: 'DATE',        x0: 0.73, x1: 0.83 },
      { key: 'revision',      label: 'REVISION',    x0: 0.83, x1: 1.0  }
    ].freeze

    # ── Paper size dialog ──────────────────────────────────────────────
    def self.show_dialog
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Paper Size',
        preferences_key: 'SketchDraw_Paper',
        width: 420, height: 320,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('paper_dialog.html'))

      dlg.add_action_callback('insert_frame') do |_ctx, size_name, cw, ch|
        begin
          if size_name == 'custom'
            insert_frame(cw.to_f, ch.to_f)
          else
            w, h = SIZES[size_name]
            insert_frame(w, h)
          end
        rescue => e
          puts "SketchDraw PaperFrame insert error: #{e.message}"
          puts e.backtrace.first(3).join("\n")
        ensure
          dlg.close
        end
      end

      dlg.add_action_callback('cancel') { dlg.close }

      dlg.add_action_callback('get_current') do |_ctx|
        frame = find_frame
        json = if frame
          w = frame.get_attribute(ATTR_NS, 'width')
          h = frame.get_attribute(ATTR_NS, 'height')
          { width: w, height: h }.to_json
        else
          'null'
        end
        dlg.execute_script("receiveCurrent(#{json})")
      end

      dlg.show
    end

    # ── Insert paper frame + title block ──────────────────────────────
    # width / height are in mm; geometry is created in SketchUp inches (.mm)
    def self.insert_frame(width, height)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Insert Paper Frame', true)

      remove_existing_frame(entities)

      w  = width.mm
      h  = height.mm

      # Center on existing drawing content if present; otherwise use origin
      ox, oy = content_origin(entities, w, h)

      frame_grp = entities.add_group
      g_ent     = frame_grp.entities

      # Border edges in local space (0,0)-(w,h); transformation positions in world
      local_pts = [
        Geom::Point3d.new(0, 0, 0),
        Geom::Point3d.new(w, 0, 0),
        Geom::Point3d.new(w, h, 0),
        Geom::Point3d.new(0, h, 0)
      ]
      face  = g_ent.add_face(local_pts)
      edges = face.edges
      face.erase!
      default_layer = model.layers['Untagged'] || model.layers[0]
      edges.each { |e| e.layer = default_layer }

      frame_grp.transformation = Geom::Transformation.new(
        Geom::Point3d.new(ox, oy, 0)
      )
      frame_grp.set_attribute(ATTR_NS, 'type',   FRAME_TAG)
      frame_grp.set_attribute(ATTR_NS, 'width',  width)
      frame_grp.set_attribute(ATTR_NS, 'height', height)
      frame_grp.name = "PaperFrame_#{width.to_i}x#{height.to_i}"

      draw_title_block(entities, width, height, ox, oy)

      State.save_to_model(model)
      model.commit_operation

      fit_view(find_frame)
    end

    # ── Programmatic title block ───────────────────────────────────────
    def self.draw_title_block(entities, width, height, ox = 0.0, oy = 0.0)
      lm   = MARGIN_LEFT.mm
      rm   = MARGIN_OTHER.mm
      tm   = MARGIN_OTHER.mm
      bm   = MARGIN_OTHER.mm
      tb_h = TB_HEIGHT.mm
      w    = width.mm
      h    = height.mm

      left   = ox + lm
      right  = ox + w - rm
      top    = oy + h - tm
      bottom = oy + bm
      tb_top = bottom + tb_h
      tw     = right - left

      tb_grp = entities.add_group
      tb_grp.set_attribute(ATTR_NS, 'type', 'title_block')
      tb_grp.name = 'SketchDraw_TitleBlock'
      g = tb_grp.entities

      [
        [left,  bottom, right, bottom],
        [right, bottom, right, top   ],
        [right, top,    left,  top   ],
        [left,  top,    left,  bottom]
      ].each do |x1, y1, x2, y2|
        g.add_line(Geom::Point3d.new(x1, y1, 0), Geom::Point3d.new(x2, y2, 0))
      end

      g.add_line(
        Geom::Point3d.new(left,  tb_top, 0),
        Geom::Point3d.new(right, tb_top, 0)
      )

      TB_COL_SPLITS.each do |frac|
        x = left + tw * frac
        g.add_line(Geom::Point3d.new(x, bottom, 0), Geom::Point3d.new(x, tb_top, 0))
      end

      current_scale_label = State.scale_ratio == 1 ? '' : "1:#{State.scale_ratio}"
      cell_pad = 1.5.mm

      TB_FIELDS.each do |fd|
        cell_x = left + tw * fd[:x0]

        lbl_grp = g.add_group
        lbl_grp.entities.add_3d_text(
          fd[:label], TextAlignLeft, 'Arial', false, false, 3.5.mm
        )
        lbl_grp.transformation = Geom::Transformation.new(
          Geom::Point3d.new(cell_x + cell_pad, bottom + tb_h * 0.30, 0)
        )

        init_val = fd[:key] == 'scale' ? current_scale_label : ''
        val_txt  = entities.add_text(
          init_val,
          Geom::Point3d.new(cell_x + cell_pad, bottom + tb_h * 0.30, 0)
        )
        val_txt.set_attribute(ATTR_NS, 'title_field', fd[:key])
      end
    end

    # ── Scale auto-update in title block (scale field removed) ───────
    def self.update_scale_in_title_block
    end

    # ── Update a single title field value ─────────────────────────────
    def self.update_title_field(field_key, value)
      model = Sketchup.active_model
      model.start_operation('Update Title Block', true)
      begin
        model.active_entities.each do |ent|
          next unless ent.is_a?(Sketchup::Text)
          next unless ent.get_attribute(ATTR_NS, 'title_field') == field_key
          begin
            ent.text = value
          rescue
            ent.string = value rescue nil
          end
        end
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "SketchDraw update_title_field error: #{e.message}"
      end
    end

    # ── Helpers ───────────────────────────────────────────────────────

    # Finds the paper frame group or component instance — checks attribute
    # first, falls back to name so detection survives attribute read failures
    # on SU 2025. Custom SKP templates are ComponentInstance; built-in frames
    # are Group.
    #
    # Searches the entire model recursively, not just top-level entities.
    # Necessary because operations like File → Import wrap the whole drawing
    # inside a component, exploding + re-grouping nests it, and saving-then-
    # inserting into a new file makes the paper frame a child of the
    # inserted component. Without recursion, PDF export would fail on any of
    # those scenarios with "No paper frame found".
    def self.find_frame(model = Sketchup.active_model)
      r = find_frame_with_xform(model)
      r ? r[0] : nil
    end

    # Same recursive search as find_frame, but also returns the transformation
    # from world coords to the frame's PARENT context. PDF export needs this
    # to convert the frame's local-space bounds to a world-space origin so
    # the drawing content (which is in world coords) lands on the PDF page.
    def self.find_frame_with_xform(model = Sketchup.active_model)
      _find_frame_in(model.entities, Geom::Transformation.new)
    end

    def self._find_frame_in(entities, ctx_xform)
      entities.each do |ent|
        next unless ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
        if ent.get_attribute(ATTR_NS, 'type') == FRAME_TAG ||
           ent.name.to_s.start_with?('PaperFrame_')
          return [ent, ctx_xform]
        end
        inner     = ent.is_a?(Sketchup::Group) ? ent.entities : ent.definition.entities
        child_ctx = ctx_xform * ent.transformation
        found     = _find_frame_in(inner, child_ctx)
        return found if found
      end
      nil
    end
    private_class_method :_find_frame_in

    def self.frame_dimensions(model = Sketchup.active_model)
      f = find_frame(model)
      return [297, 210] unless f
      [f.get_attribute(ATTR_NS, 'width').to_f,
       f.get_attribute(ATTR_NS, 'height').to_f]
    end

    def self.remove_existing_frame(entities)
      to_erase = []
      entities.each do |ent|
        next unless ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
        t = ent.get_attribute(ATTR_NS, 'type')
        to_erase << ent if t == FRAME_TAG || t == 'title_block' ||
                           ent.name.to_s.start_with?('PaperFrame_')
      end
      entities.grep(Sketchup::Text).each do |txt|
        to_erase << txt unless txt.get_attribute(ATTR_NS, 'title_field').nil?
      end
      entities.erase_entities(to_erase) unless to_erase.empty?
    end

    def self.fit_view(frame_entity = nil)
      view   = Sketchup.active_model.active_view
      camera = view.camera
      camera.perspective = false
      target = (frame_entity && frame_entity.valid?) ? frame_entity : find_frame
      if target
        c = target.bounds.center
        camera.set(
          Geom::Point3d.new(c.x, c.y, 1000.mm),
          Geom::Point3d.new(c.x, c.y, 0),
          Geom::Vector3d.new(0, 1, 0)
        )
        view.zoom(target)
      else
        view.zoom_extents
      end
    end

    # Returns the world-space origin (ox, oy) for the paper frame.
    # - Empty model → (0, 0)
    # - Any existing content → frame placed to the right with a gap (never overlaps)
    def self.content_origin(entities, w, h)
      bb = Geom::BoundingBox.new
      entities.each do |ent|
        next if ent.is_a?(Sketchup::Text)
        bb.add(ent.bounds) if ent.respond_to?(:bounds)
      end
      return [0.0, 0.0] unless bb.valid?

      gap = 50.0.mm
      [bb.max.x + gap, bb.center.y - h / 2.0]
    end
    private_class_method :content_origin

    def self.ui_path(file)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', file)
    end

    # ── Load Custom Template (user-supplied SKP) ─────────────────────
    # Lets the user drop in their own frame + title block from a .skp file.
    # The imported component is tagged as a paper frame so PDF export uses it
    # in place of the built-in generated frame.
    def self.load_template
      return unless SketchDraw.version_ok?

      path = UI.openpanel('Select Template (SketchUp file)', '', 'SketchUp Model|*.skp||')
      return unless path
      unless File.exist?(path)
        UI.messagebox("File not found:\n#{path}", MB_OK)
        return
      end

      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Load Custom Template', true)

      begin
        remove_existing_frame(entities)

        defn = model.definitions.load(path)
        bb   = defn.bounds
        w_in = bb.width
        h_in = bb.height
        if w_in < 1.mm || h_in < 1.mm
          model.abort_operation
          UI.messagebox('Template appears empty (zero size). Please check the SKP file.', MB_OK)
          return
        end

        # Place beside existing content (or at origin)
        ox, oy = existing_content_origin(entities, w_in, h_in)
        # Shift so the definition's own min corner sits at (ox, oy)
        tx = ox - bb.min.x
        ty = oy - bb.min.y
        inst = entities.add_instance(
          defn,
          Geom::Transformation.new(Geom::Vector3d.new(tx, ty, 0))
        )

        inst.set_attribute(ATTR_NS, 'type',   FRAME_TAG)
        inst.set_attribute(ATTR_NS, 'width',  w_in.to_mm)
        inst.set_attribute(ATTR_NS, 'height', h_in.to_mm)
        inst.set_attribute(ATTR_NS, 'custom_template', true)
        base = File.basename(path, '.skp').gsub(/[^A-Za-z0-9_-]/, '_')[0, 40]
        inst.name = "PaperFrame_#{base}"

        State.save_to_model(model)
        model.commit_operation

        fit_view(inst)
        UI.messagebox(
          "Template loaded:\n#{File.basename(path)}\n\n" \
          "Size: #{w_in.to_mm.round}mm x #{h_in.to_mm.round}mm\n\n" \
          "Edit the text fields directly in SketchUp, then run PDF Export.",
          MB_OK
        )
      rescue => e
        model.abort_operation rescue nil
        UI.messagebox("Template load failed:\n#{e.class}: #{e.message}", MB_OK)
      end
    end

    # Same layout logic as content_origin but exposed for load_template
    def self.existing_content_origin(entities, w, h)
      bb = Geom::BoundingBox.new
      entities.each do |ent|
        next if ent.is_a?(Sketchup::Text)
        bb.add(ent.bounds) if ent.respond_to?(:bounds)
      end
      return [0.0, 0.0] unless bb.valid?
      gap = 50.0.mm
      [bb.max.x + gap, bb.center.y - h / 2.0]
    end
    private_class_method :existing_content_origin
  end
end
