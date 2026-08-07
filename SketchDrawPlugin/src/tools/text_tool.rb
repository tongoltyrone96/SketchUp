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
        # Reuse the ORIGINAL placement point stored at creation time.
        # Using `group.bounds.min` here (the previous behaviour) shifted the
        # text every time it was edited: bounds depend on line count and
        # alignment, so re-using them as the new origin caused the text to
        # slide down/left on every re-edit.
        origin = read_text_origin(group)
        group.entities.clear!
        build_text_content(group.entities, origin, props)
        group.set_attribute(ATTR_NS, 'text_props', props.to_json)
        # Keep the stored origin in sync (a no-op for groups already created
        # with an origin attribute; heals legacy groups that don't have one).
        group.set_attribute(ATTR_NS, 'origin',
                            [origin.x.to_f, origin.y.to_f, origin.z.to_f])
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
      # Persist the placement point so future edits can reuse it exactly.
      group.set_attribute(ATTR_NS, 'origin',
                          [origin.x.to_f, origin.y.to_f, origin.z.to_f])
      group.name = 'SketchDraw_Text'
      group
    end

    # Retrieve the point the text was placed at. Falls back to a bounds-based
    # estimate for old groups saved before the 'origin' attribute existed —
    # `bounds.max.y` is closer to the first-line baseline than `bounds.min.y`
    # (which caused the drift bug), and this fallback runs at most once per
    # legacy group because `update_text_group` writes the attribute back.
    def self.read_text_origin(group)
      raw = group.get_attribute(ATTR_NS, 'origin')
      if raw.is_a?(Array) && raw.length >= 3
        return Geom::Point3d.new(raw[0].to_f, raw[1].to_f, raw[2].to_f)
      end
      b = group.bounds
      Geom::Point3d.new(b.min.x, b.max.y, b.min.z)
    end

    def self.build_text_content(g_entities, origin, props)
      model   = Sketchup.active_model
      font    = props[:font]   || 'Arial'
      bold    = props[:bold]   == true || props[:bold]   == 'true'
      italic  = props[:italic] == true || props[:italic] == 'true'
      # Base height at paper scale: 10pt ≈ 3.5mm on paper.
      base_h  = (props[:size_pt].to_f * 0.3528).mm
      base_h  = 3.5.mm if base_h <= 0
      # Scale up when placed outside a paper frame so the text is visible
      # at world scale (3.5mm on a 17-metre scaffold is sub-pixel and
      # invisible — the "text 안 보인다" bug on the scaffold view). Inside
      # a paper frame the multiplier is 1.0 so paper output is unchanged.
      height  = base_h * SketchDraw::State.paper_scale_multiplier_at(model, origin)

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

        # add_3d_text filled=true can create a large background rectangle face.
        # Identify it as the face with area >> all other faces, then remove it.
        if all_faces.length > 1
          sorted = all_faces.sort_by(&:area)
          if sorted.last.area > sorted[-2].area * 3.0
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
