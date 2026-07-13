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

    # Inner-margin constants (drawing units = mm)
    MARGIN_LEFT  = 25.0   # wider left side for binding
    MARGIN_OTHER = 10.0   # top / right / bottom
    TB_HEIGHT    = 25.0   # title block height

    # Title block column splits (cumulative fractions, left → right)
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
        if size_name == 'custom'
          insert_frame(cw.to_f, ch.to_f)
        else
          w, h = SIZES[size_name]
          insert_frame(w, h)
        end
        dlg.close
      end

      dlg.add_action_callback('cancel') { dlg.close }

      dlg.add_action_callback('get_current') do |action_ctx|
        frame = find_frame
        if frame
          w = frame.get_attribute(ATTR_NS, 'width')
          h = frame.get_attribute(ATTR_NS, 'height')
          action_ctx.resolve({ width: w, height: h }.to_json)
        else
          action_ctx.resolve('null')
        end
      end

      dlg.show
    end

    # ── Insert paper frame + title block ──────────────────────────────
    def self.insert_frame(width, height)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Insert Paper Frame', true)

      remove_existing_frame(entities)

      # Outer border — thin-edge group (no filled face for cleaner PDF)
      pts = [
        Geom::Point3d.new(0,     0,      0),
        Geom::Point3d.new(width, 0,      0),
        Geom::Point3d.new(width, height, 0),
        Geom::Point3d.new(0,     height, 0)
      ]
      frame_grp = entities.add_group
      g_ent     = frame_grp.entities
      edges     = g_ent.add_face(pts).edges
      edges.each { |e| e.layer = model.layers.at(0) }

      frame_grp.set_attribute(ATTR_NS, 'type',   FRAME_TAG)
      frame_grp.set_attribute(ATTR_NS, 'width',  width)
      frame_grp.set_attribute(ATTR_NS, 'height', height)
      frame_grp.name = "PaperFrame_#{width.to_i}x#{height.to_i}"

      # Programmatic inner border + title block (no .skp dependency)
      draw_title_block(entities, width, height)

      fit_view(width, height)
      State.save_to_model(model)
      model.commit_operation
    end

    # ── Programmatic title block ───────────────────────────────────────
    def self.draw_title_block(entities, width, height)
      lm = MARGIN_LEFT
      rm = MARGIN_OTHER
      tm = MARGIN_OTHER
      bm = MARGIN_OTHER
      tb_h = TB_HEIGHT

      left   = lm
      right  = width  - rm
      top    = height - tm
      bottom = bm
      tb_top = bottom + tb_h
      tw     = right - left  # total title block width

      # Structural lines group (inner border + title block grid)
      tb_grp = entities.add_group
      tb_grp.set_attribute(ATTR_NS, 'type', 'title_block')
      tb_grp.name = 'SketchDraw_TitleBlock'
      g = tb_grp.entities

      # Inner border (4 edges)
      [
        [left,  bottom, right, bottom],
        [right, bottom, right, top   ],
        [right, top,    left,  top   ],
        [left,  top,    left,  bottom]
      ].each do |x1, y1, x2, y2|
        g.add_line(Geom::Point3d.new(x1, y1, 0), Geom::Point3d.new(x2, y2, 0))
      end

      # Horizontal separator above title block
      g.add_line(
        Geom::Point3d.new(left,  tb_top, 0),
        Geom::Point3d.new(right, tb_top, 0)
      )

      # Vertical column dividers
      TB_COL_SPLITS.each do |frac|
        x = left + tw * frac
        g.add_line(Geom::Point3d.new(x, bottom, 0), Geom::Point3d.new(x, tb_top, 0))
      end

      # Scale initial value from current State
      current_scale_label = State.scale_ratio == 1 ? '1:1' : "1:#{State.scale_ratio}"

      cell_pad = 1.5

      TB_FIELDS.each do |fd|
        cell_x = left + tw * fd[:x0]

        # Field label: 3D geometry text for reliable positioning (upper cell zone)
        lbl_grp = g.add_group
        lbl_grp.entities.add_3d_text(
          fd[:label], TextAlignLeft, 'Arial', false, false, 3.5
        )
        lbl_grp.transformation = Geom::Transformation.new(
          Geom::Point3d.new(cell_x + cell_pad, bottom + tb_h * 0.30, 0)
        )

        # Editable value annotation (root level so update_title_field can find it)
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
      ratio = State.scale_ratio
      label = ratio == 1 ? '1:1' : "1:#{ratio}"
      update_title_field('scale', label)
    end

    # ── Update a single title field value ─────────────────────────────
    def self.update_title_field(field_key, value)
      model = Sketchup.active_model
      model.start_operation('Update Title Block', true)
      model.active_entities.grep(Sketchup::Text).each do |txt|
        if txt.get_attribute(ATTR_NS, 'title_field') == field_key
          txt.string = value
        end
      end
      model.commit_operation
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

    def self.fit_view(width, height)
      view   = Sketchup.active_model.active_view
      camera = view.camera
      camera.perspective = false
      cx = width  / 2.0
      cy = height / 2.0
      camera.set(
        Geom::Point3d.new(cx, cy, 1000),
        Geom::Point3d.new(cx, cy, 0),
        Geom::Vector3d.new(0, 1, 0)
      )
      bb = Geom::BoundingBox.new
      bb.add(Geom::Point3d.new(0,     0,      0))
      bb.add(Geom::Point3d.new(width, height, 0))
      view.zoom(bb)
    end

    def self.ui_path(file)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', file)
    end
  end
end
