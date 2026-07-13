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
        preferences_key: 'SketchDraw_Text',
        width: 540, height: 500,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('text_dialog.html'))

      dlg.add_action_callback('get_tags') do |action_ctx|
        tags = Sketchup.active_model.layers.map(&:name).sort
        action_ctx.resolve(tags.to_json)
      end

      dlg.add_action_callback('get_props') do |action_ctx|
        if existing_group
          props = existing_group.get_attribute(ATTR_NS, 'text_props', '{}')
          action_ctx.resolve(props)
        else
          action_ctx.resolve('null')
        end
      end

      dlg.add_action_callback('place_text') do |_ctx, json|
        props = JSON.parse(json, symbolize_names: true)
        dlg.close
        if existing_group
          update_text_group(existing_group, props)
        else
          Sketchup.active_model.select_tool(TextPlacementTool.new(props))
        end
      end

      dlg.show
    end

    def self.place_text_at(origin, props)
      model    = Sketchup.active_model
      entities = model.active_entities
      model.start_operation('Place Text', true)

      group = build_text_group(entities, origin, props)
      tag   = props[:tag].to_s
      if tag && !tag.empty?
        layer = model.layers[tag] || model.layers.add(tag)
        group.layer = layer
      end

      model.commit_operation
    end

    def self.update_text_group(group, props)
      model = Sketchup.active_model
      model.start_operation('Edit Text', true)
      origin = group.bounds.min
      group.entities.clear!
      build_text_content(group.entities, origin, props)
      group.set_attribute(ATTR_NS, 'text_props', props.to_json)
      model.commit_operation
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
      font    = props[:font]    || 'Arial'
      bold    = props[:bold]    == true || props[:bold]    == 'true'
      italic  = props[:italic]  == true || props[:italic]  == 'true'
      height  = (props[:size_pt].to_f * 0.3528).mm
      color   = Sketchup::Color.new(props[:color] || '#000000')
      content = props[:is_caps] == true ? props[:content].to_s.upcase
                                        : props[:content].to_s

      lines        = content.split("\n")
      line_spacing = height * 1.4

      lines.each_with_index do |line_text, i|
        line_text = line_text.strip
        next if line_text.empty?

        prefix = case props[:list_style]
                 when 'dot'    then '• '
                 when 'dash'   then '- '
                 when 'number' then "#{i + 1}. "
                 else ''
                 end

        display_text = prefix + line_text
        y_offset     = -(i * line_spacing)
        pt           = Geom::Point3d.new(origin.x, origin.y + y_offset, origin.z)

        g_entities.add_3d_text(
          display_text,
          TextAlignLeft,
          font,
          bold,
          italic,
          height,
          0.0,
          0.0,
          true,
          0.0
        )

        g_entities.grep(Sketchup::Face).each do |f|
          f.material      = color
          f.back_material = color
        end
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
