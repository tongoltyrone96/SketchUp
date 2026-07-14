module SketchDraw
  module TextTool
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.activate
      return unless SketchDraw.version_ok?
      show_dialog
    end

    def self.show_dialog(existing_group = nil)
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Text Tool',
        preferences_key: 'SketchDraw_Text_v2',
        width: 480, height: 380,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('text_dialog.html'))

      dlg.add_action_callback('get_props') do |_ctx|
        if existing_group
          props = existing_group.get_attribute(ATTR_NS, 'text_props', 'null')
          dlg.execute_script("receiveProps(#{props})")
        else
          dlg.execute_script('receiveProps(null)')
        end
      end

      dlg.add_action_callback('place_text') do |_ctx, json|
        begin
          props = JSON.parse(json, symbolize_names: true)
          dlg.close
          if existing_group
            update_text_group(existing_group, props)
          else
            Sketchup.active_model.select_tool(TextPlacementTool.new(props))
          end
        rescue => e
          puts "SketchDraw TextTool error: #{e.message}"
          puts e.backtrace.first(3).join("\n")
        end
      end

      dlg.add_action_callback('cancel') { dlg.close }

      dlg.show
    end

    def self.place_text_at(origin, props)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Place Text', true)
      begin
        build_text_group(entities, origin, props)
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "SketchDraw place_text_at error: #{e.message}"
        puts e.backtrace.first(3).join("\n")
      end
    end

    def self.update_text_group(group, props)
      model = Sketchup.active_model
      model.start_operation('Edit Text', true)
      begin
        origin = group.bounds.min
        group.entities.clear!
        build_text_content(group.entities, origin, props)
        group.set_attribute(ATTR_NS, 'text_props', props.to_json)
        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "SketchDraw update_text_group error: #{e.message}"
      end
    end

    def self.build_text_group(entities, origin, props)
      group = entities.add_group
      build_text_content(group.entities, origin, props)
      group.set_attribute(ATTR_NS, 'type',       'text')
      group.set_attribute(ATTR_NS, 'text_props', props.to_json)
      group.name = 'SketchDraw_Text'
      group
    end

    def self.build_text_content(g_entities, origin, props)
      model   = Sketchup.active_model
      font    = props[:font]   || 'Arial'
      bold    = props[:bold]   == true || props[:bold]   == 'true'
      italic  = props[:italic] == true || props[:italic] == 'true'
      height  = props[:size_pt].to_f * 0.3528  # pt → mm, direct SU units (no .mm)
      height  = 3.5 if height <= 0

      hex     = (props[:color] || '#000000').gsub('#', '')
      r, g, b = hex.scan(/../).map { |h| h.to_i(16) }
      mat_name  = "SKD_#{hex}"
      color_mat = model.materials[mat_name] || model.materials.add(mat_name)
      color_mat.color = Sketchup::Color.new(r, g, b)

      content = props[:is_caps] == true ? props[:content].to_s.upcase
                                        : props[:content].to_s

      lines        = content.split("\n")
      line_spacing = height * 1.4

      lines.each_with_index do |line_text, i|
        line_text = line_text.strip
        next if line_text.empty?

        y_pos    = origin.y - (i * line_spacing)
        align_const = case (props[:align] || 'L').to_s.upcase
                      when 'C' then TextAlignCenter
                      when 'R' then TextAlignRight
                      else TextAlignLeft
                      end

        line_grp = g_entities.add_group
        line_grp.entities.add_3d_text(
          line_text,
          align_const,
          font,
          bold,
          italic,
          height,
          0.0, 0.0,
          true,
          0.0
        )
        line_grp.transformation = Geom::Transformation.new(
          Geom::Point3d.new(origin.x, y_pos, origin.z)
        )

        all_faces = line_grp.entities.grep(Sketchup::Face)
        puts "SketchDraw '#{line_text}': #{all_faces.length} faces, areas=[#{all_faces.map { |f| f.area.round(3) }.join(',')}]"

        # add_3d_text filled=true can create a large background rectangle face.
        # Identify it as the face with area >> all other faces, then remove it.
        if all_faces.length > 1
          sorted = all_faces.sort_by(&:area)
          if sorted.last.area > sorted[-2].area * 3.0
            puts "SketchDraw: removing background face (area=#{sorted.last.area.round(3)})"
            line_grp.entities.erase_entities([sorted.last])
          end
        end

        line_grp.entities.grep(Sketchup::Face).each do |f|
          f.material      = color_mat
          f.back_material = color_mat
        end
        line_grp.entities.grep(Sketchup::Edge).each { |e| e.hidden = true }
      end
    end

    def self.ui_path(f)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', f)
    end
  end

  class TextPlacementTool
    def initialize(props)
      @props = props
    end

    def activate
      Sketchup.set_status_text('Click to place text')
    end

    def onLButtonDown(_flags, x, y, view)
      ip = Sketchup::InputPoint.new
      ip.pick(view, x, y)
      pt = Geom::Point3d.new(ip.position.x, ip.position.y, 0)
      TextTool.place_text_at(pt, @props)
      Sketchup.active_model.select_tool(nil)
    end

    def onKeyDown(key, _r, _f, _v)
      Sketchup.active_model.select_tool(nil) if key == 27
    end
  end
end
