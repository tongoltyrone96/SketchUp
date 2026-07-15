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

    # Inner-margin constants (mm)
    MARGIN_LEFT  = 25.0
    MARGIN_OTHER = 10.0
    TB_HEIGHT    = 25.0

    TB_COL_SPLITS = [0.28, 0.55, 0.73, 0.83, 0.93].freeze

    TB_FIELDS = [
      { key: 'project_name',  label: 'PROJECT',   x0: 0.0,  x1: 0.28 },
      { key: 'drawing_title', label: 'TITLE',      x0: 0.28, x1: 0.55 },
      { key: 'drawn_by',      label: 'DRAWN BY',   x0: 0.55, x1: 0.73 },
      { key: 'date',          label: 'DATE',        x0: 0.73, x1: 0.83 },
      { key: 'revision',      label: 'REVISION',    x0: 0.83, x1: 0.93 },
      { key: 'scale',         label: 'SCALE',       x0: 0.93, x1: 1.0  }
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

      w = width.mm
      h = height.mm

      pts = [
        Geom::Point3d.new(0, 0, 0),
        Geom::Point3d.new(w, 0, 0),
        Geom::Point3d.new(w, h, 0),
        Geom::Point3d.new(0, h, 0)
      ]
      frame_grp = entities.add_group
      g_ent     = frame_grp.entities
      face      = g_ent.add_face(pts)
      edges     = face.edges
      face.erase!
      edges.each { |e| e.layer = model.layers.at(0) }

      frame_grp.set_attribute(ATTR_NS, 'type',   FRAME_TAG)
      frame_grp.set_attribute(ATTR_NS, 'width',  width)
      frame_grp.set_attribute(ATTR_NS, 'height', height)
      frame_grp.name = "PaperFrame_#{width.to_i}x#{height.to_i}"

      draw_title_block(entities, width, height)

      fit_view(width, height, frame_grp)
      State.save_to_model(model)
      model.commit_operation
    end

    # ── Programmatic title block ───────────────────────────────────────
    def self.draw_title_block(entities, width, height)
      # All mm values converted to SketchUp inches with .mm
      lm   = MARGIN_LEFT.mm
      rm   = MARGIN_OTHER.mm
      tm   = MARGIN_OTHER.mm
      bm   = MARGIN_OTHER.mm
      tb_h = TB_HEIGHT.mm
      w    = width.mm
      h    = height.mm

      left   = lm
      right  = w - rm
      top    = h - tm
      bottom = bm
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

    # ── Scale auto-update in title block ──────────────────────────────
    def self.update_scale_in_title_block
      update_title_field('scale', '')
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
    def self.find_frame(model = Sketchup.active_model)
      model.active_entities.grep(Sketchup::Group).find do |g|
        g.get_attribute(ATTR_NS, 'type') == FRAME_TAG
      end
    end

    def self.frame_dimensions(model = Sketchup.active_model)
      f = find_frame(model)
      return [297, 210] unless f
      [f.get_attribute(ATTR_NS, 'width').to_f,
       f.get_attribute(ATTR_NS, 'height').to_f]
    end

    def self.remove_existing_frame(entities)
      to_erase = []
      entities.grep(Sketchup::Group).each do |g|
        t = g.get_attribute(ATTR_NS, 'type')
        to_erase << g if t == FRAME_TAG || t == 'title_block'
      end
      entities.grep(Sketchup::Text).each do |txt|
        to_erase << txt unless txt.get_attribute(ATTR_NS, 'title_field').nil?
      end
      entities.erase_entities(to_erase) unless to_erase.empty?
    end

    def self.fit_view(width, height, frame_entity = nil)
      view   = Sketchup.active_model.active_view
      camera = view.camera
      camera.perspective = false
      cx = width.mm  / 2.0
      cy = height.mm / 2.0
      camera.set(
        Geom::Point3d.new(cx, cy, 1000.mm),
        Geom::Point3d.new(cx, cy, 0),
        Geom::Vector3d.new(0, 1, 0)
      )
      if frame_entity && frame_entity.valid?
        view.zoom(frame_entity)
      else
        existing = find_frame
        existing ? view.zoom(existing) : view.zoom_extents
      end
    end

    def self.ui_path(file)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', file)
    end
  end
end
