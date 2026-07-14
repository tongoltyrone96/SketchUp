module SketchDraw
  module ArrowTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.activate
      return unless SketchDraw.version_ok?
      show_dialog
    end

    def self.show_dialog(existing_group = nil)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Arrow Label',
        preferences_key: 'SketchDraw_Arrow_v2',
        width: 420, height: 440,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('arrow_dialog.html'))

      dlg.add_action_callback('get_props') do |_ctx|
        if existing_group
          props = existing_group.get_attribute(ATTR_NS, 'arrow_props', 'null')
          dlg.execute_script("receiveProps(#{props})")
        else
          dlg.execute_script('receiveProps(null)')
        end
      end

      dlg.add_action_callback('place_arrow') do |_ctx, json|
        begin
          data = JSON.parse(json, symbolize_names: true)
          dlg.close
          if existing_group
            update_arrow(existing_group, data)
          else
            Sketchup.active_model.select_tool(ArrowPlacementTool.new(data))
          end
        rescue => e
          puts "SketchDraw ArrowTool error: #{e.message}"
          puts e.backtrace.first(3).join("\n")
        end
      end

      dlg.add_action_callback('cancel') { dlg.close }

      dlg.show
    end

    def self.show_edit_dialog(group)
      show_dialog(group)
    end

    def self.place_arrow_at(tip, line_end, data)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Place Arrow', true)
      begin
        build_arrow_group(entities, tip, line_end, data)
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "SketchDraw place_arrow_at error: #{e.message}"
        puts e.backtrace.first(3).join("\n")
      end
    end

    def self.update_arrow(group, data)
      model = Sketchup.active_model
      model.start_operation('Edit Arrow', true)
      begin
        tx = group.get_attribute(ATTR_NS, 'tip_x', nil)
        ex = group.get_attribute(ATTR_NS, 'line_end_x', nil)

        if tx && ex
          tip      = Geom::Point3d.new(tx.to_f,
                       group.get_attribute(ATTR_NS, 'tip_y',      0).to_f,
                       group.get_attribute(ATTR_NS, 'tip_z',      0).to_f)
          line_end = Geom::Point3d.new(ex.to_f,
                       group.get_attribute(ATTR_NS, 'line_end_y', 0).to_f,
                       group.get_attribute(ATTR_NS, 'line_end_z', 0).to_f)
        else
          # Fallback for arrows stored with old JSON array attributes
          tip_raw  = group.get_attribute(ATTR_NS, 'tip',      nil)
          tail_raw = group.get_attribute(ATTR_NS, 'line_end', nil)
          if tip_raw && tail_raw
            tip_arr      = tip_raw.is_a?(Array)  ? tip_raw  : JSON.parse(tip_raw)
            tail_arr     = tail_raw.is_a?(Array) ? tail_raw : JSON.parse(tail_raw)
            tip      = Geom::Point3d.new(*tip_arr)
            line_end = Geom::Point3d.new(*tail_arr)
          else
            bb       = group.bounds
            tip      = bb.max
            line_end = bb.min
            puts 'SketchDraw update_arrow: coords missing, using bounds fallback'
          end
        end

        puts "SketchDraw update_arrow: tip=#{tip.inspect}, line_end=#{line_end.inspect}"
        group.entities.clear!
        build_arrow_content(group.entities, tip, line_end, data)
        group.set_attribute(ATTR_NS, 'arrow_props', data.to_json)
        model.commit_operation
        puts 'SketchDraw update_arrow: committed OK'
        model.active_view.invalidate
      rescue => e
        model.abort_operation rescue nil
        puts "SketchDraw update_arrow error: #{e.message}"
        puts e.backtrace.first(5).join("\n")
      end
    end

    def self.build_arrow_group(entities, tip, line_end, data)
      group = entities.add_group
      build_arrow_content(group.entities, tip, line_end, data)
      group.set_attribute(ATTR_NS, 'type',        'arrow')
      group.set_attribute(ATTR_NS, 'arrow_props', data.to_json)
      group.set_attribute(ATTR_NS, 'tip_x',       tip.x.to_f)
      group.set_attribute(ATTR_NS, 'tip_y',       tip.y.to_f)
      group.set_attribute(ATTR_NS, 'tip_z',       tip.z.to_f)
      group.set_attribute(ATTR_NS, 'line_end_x',  line_end.x.to_f)
      group.set_attribute(ATTR_NS, 'line_end_y',  line_end.y.to_f)
      group.set_attribute(ATTR_NS, 'line_end_z',  line_end.z.to_f)
      group.name = 'SketchDraw_Arrow'
      group
    end

    def self.build_arrow_content(g_entities, tip, line_end, data)
      model = Sketchup.active_model

      hex_a      = (data[:arrow_color] || '#000000').gsub('#', '')
      ra, ga, ba = hex_a.scan(/../).map { |h| h.to_i(16) }
      arrow_mat  = model.materials["SKD_#{hex_a}"] || model.materials.add("SKD_#{hex_a}")
      arrow_mat.color = Sketchup::Color.new(ra, ga, ba)

      arrow_size = (data[:arrow_size] || 3.0).to_f   # direct SU units = mm
      line_width = arrow_size * 0.15                  # thickness proportional to arrow size

      dir = tip.vector_to(line_end)
      return unless dir.valid? && dir.length > 0.001
      dir.normalize!
      perp = Geom::Vector3d.new(-dir.y, dir.x, 0).normalize

      # Arrowhead base (where triangle meets the leader line), between tip and tail
      base = tip.offset(dir, arrow_size)

      # Leader line as a thin face rectangle (base → tail)
      # Drawn separately from arrowhead to avoid coplanar face merging
      hw   = line_width / 2.0
      lp1  = base.offset(perp,  hw)
      lp2  = base.offset(perp, -hw)
      lp3  = line_end.offset(perp, -hw)
      lp4  = line_end.offset(perp,  hw)
      line_face = g_entities.add_face([lp1, lp2, lp3, lp4])
      if line_face
        line_face.material      = arrow_mat
        line_face.back_material = arrow_mat
        line_face.edges.each { |e| e.hidden = true }
      end

      # Arrowhead triangle in its own sub-group to prevent coplanar merging with line face
      arrow_grp = g_entities.add_group
      left      = base.offset(perp,  arrow_size * 0.4)
      right     = base.offset(perp, -arrow_size * 0.4)
      ah_face   = arrow_grp.entities.add_face(tip, left, right)
      if ah_face
        ah_face.material      = arrow_mat
        ah_face.back_material = arrow_mat
        ah_face.edges.each { |e| e.hidden = true }
      end

      # Label text: centered over the midpoint of the line, offset perpendicular
      label = data[:label].to_s.strip
      unless label.empty?
        font      = data[:font] || 'Arial'
        text_size = (data[:text_size] || 10.0).to_f
        text_h    = text_size * 0.3528
        mid       = Geom::Point3d.new(
          (tip.x + line_end.x) / 2.0,
          (tip.y + line_end.y) / 2.0,
          0
        )
        label_perp   = (perp.y < -0.001) ? perp.reverse : perp
        label_origin = mid.offset(label_perp, text_h * 0.6 + line_width + 1.0)
        TextTool.build_text_group(g_entities, label_origin, {
          content:    label,
          font:       font,
          size_pt:    text_size,
          bold:       data[:text_bold],
          italic:     false,
          color:      data[:text_color] || '#000000',
          align:      'C',
          list_style: 'none',
          is_caps:    false
        })
      end
    end

    def self.ui_path(f)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', f)
    end
  end

  class ArrowPlacementTool
    def initialize(props)
      @props = props
      @tail  = nil   # first click = line start (no arrowhead here)
      @ip    = Sketchup::InputPoint.new
    end

    def activate
      Sketchup.set_status_text('Click line start point')
    end

    def onMouseMove(_flags, x, y, view)
      @ip.pick(view, x, y)
      view.invalidate
    end

    def draw(view)
      return unless @tail
      view.line_width    = 1
      view.line_stipple  = ''
      view.drawing_color = Sketchup::Color.new('cyan')
      view.draw_line(@tail, @ip.position)
    end

    def onLButtonDown(_flags, x, y, view)
      @ip.pick(view, x, y)
      pt = Geom::Point3d.new(@ip.position.x, @ip.position.y, 0)

      if @tail.nil?
        @tail = pt   # first click = line start / tail
        Sketchup.set_status_text('Click arrowhead tip point')
      else
        # second click = arrowhead tip
        # place_arrow_at(tip, line_end, data): tip=second click, line_end=first click
        ArrowTool.place_arrow_at(pt, @tail, @props)
        Sketchup.active_model.select_tool(nil)
      end
      view.invalidate
    end

    def onKeyDown(key, _r, _f, _v)
      Sketchup.active_model.select_tool(nil) if key == 27
    end
  end
end
