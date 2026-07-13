module SketchDraw
  class ArrowTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.activate
      return unless SketchDraw.version_ok?
      Sketchup.active_model.select_tool(new)
    end

    def self.show_edit_dialog(group)
      show_label_dialog(nil, nil, group)
    end

    def initialize
      @tip      = nil
      @line_end = nil
      @ip       = Sketchup::InputPoint.new
    end

    def activate
      Sketchup.set_status_text('Click arrowhead tip point')
    end

    def onMouseMove(_flags, x, y, view)
      @ip.pick(view, x, y)
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      @ip.pick(view, x, y)
      pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)

      if @tip.nil?
        @tip = pt
        Sketchup.set_status_text('Click leader line end point')
      elsif @line_end.nil?
        @line_end = pt
        Sketchup.set_status_text('Enter label text in dialog...')
        ArrowTool.show_label_dialog(@tip, @line_end)
        Sketchup.active_model.select_tool(nil)
      end
      view.invalidate
    end

    def draw(view)
      return unless @tip
      pos = @ip.position
      view.line_width    = 1
      view.drawing_color = Sketchup::Color.new('cyan')
      view.draw_line(@tip, pos)
    end

    def onKeyDown(key, _r, _f, _v)
      Sketchup.active_model.select_tool(nil) if key == 27
    end

    def self.show_label_dialog(tip, line_end, existing_group = nil)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Arrow Label',
        preferences_key: 'SketchDraw_Arrow',
        width: 420, height: 360,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('arrow_dialog.html'))

      dlg.add_action_callback('get_props') do |action_ctx|
        if existing_group
          props = existing_group.get_attribute(ATTR_NS, 'arrow_props', '{}')
          action_ctx.resolve(props)
        else
          action_ctx.resolve('null')
        end
      end

      dlg.add_action_callback('place_arrow') do |_ctx, json|
        data = JSON.parse(json, symbolize_names: true)
        dlg.close
        if existing_group
          update_arrow(existing_group, data)
        else
          place_arrow(tip, line_end, data)
        end
      end

      dlg.show
    end

    def self.place_arrow(tip, line_end, data)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Place Arrow Label', true)

      group = entities.add_group
      g_ent = group.entities

      arrow_color = Sketchup::Color.new(data[:arrow_color] || '#ffffff')
      text_color  = Sketchup::Color.new(data[:text_color]  || '#ffffff')
      arrow_size  = (data[:arrow_size] || 3.0).to_f.mm
      font        = data[:font] || 'Arial'
      text_size   = (data[:text_size] || 10.0).to_f

      edge = g_ent.add_line(tip, line_end)
      edge.material = arrow_color

      dir = line_end.vector_to(tip)
      if dir.valid?
        dir.normalize!
        perp = Geom::Vector3d.new(-dir.y, dir.x, 0)
        perp.normalize!
        base  = tip.offset(dir.reverse, arrow_size)
        left  = base.offset(perp,  arrow_size * 0.4)
        right = base.offset(perp, -arrow_size * 0.4)
        face  = g_ent.add_face(tip, left, right)
        if face
          face.material      = arrow_color
          face.back_material = arrow_color
        end
      end

      unless data[:label].to_s.strip.empty?
        label_origin = Geom::Point3d.new(
          line_end.x + 2.mm,
          line_end.y + 2.mm,
          0
        )
        TextTool.place_text_at(label_origin, {
          content:    data[:label],
          font:       font,
          size_pt:    text_size,
          bold:       data[:text_bold],
          italic:     false,
          color:      data[:text_color] || '#ffffff',
          list_style: 'none',
          is_caps:    false
        })
      end

      group.set_attribute(ATTR_NS, 'type',        'arrow')
      group.set_attribute(ATTR_NS, 'arrow_props', data.to_json)
      group.name = 'SketchDraw_Arrow'

      model.commit_operation
    end

    def self.update_arrow(group, data)
      model = Sketchup.active_model
      model.start_operation('Edit Arrow', true)
      bb   = group.bounds
      tip  = bb.min
      tail = bb.max
      group.erase!
      place_arrow(tip, tail, data)
      model.commit_operation
    end

    def self.ui_path(f)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', f)
    end
  end
end
