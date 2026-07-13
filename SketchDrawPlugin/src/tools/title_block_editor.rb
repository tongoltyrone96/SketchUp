module SketchDraw
  module TitleBlockEditor
    def self.show_dialog
      dlg = UI::HtmlDialog.new(
        dialog_title:    'Edit Title Block',
        preferences_key: 'SketchDraw_TitleBlock',
        width: 440, height: 380,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      dlg.set_file(ui_path('title_block_dialog.html'))

      dlg.add_action_callback('get_fields') do |action_ctx|
        fields = load_current_fields
        action_ctx.resolve(fields.to_json)
      end

      dlg.add_action_callback('save_fields') do |_ctx, json|
        data = JSON.parse(json, symbolize_names: true)
        apply_fields(data)
        dlg.close
      end

      dlg.show
    end

    def self.apply_fields(data)
      model = Sketchup.active_model
      model.start_operation('Edit Title Block', true)

      data.each do |field_key, value|
        model.active_entities.grep(Sketchup::Text).each do |txt|
          if txt.get_attribute(SketchDraw::PLUGIN_ID, 'title_field') == field_key.to_s
            txt.string = value.to_s
          end
        end
      end

      PaperFrame.update_scale_in_title_block
      model.commit_operation
    end

    def self.load_current_fields
      fields = {}
      Sketchup.active_model.active_entities.grep(Sketchup::Text).each do |txt|
        key = txt.get_attribute(SketchDraw::PLUGIN_ID, 'title_field')
        fields[key] = txt.string if key
      end
      fields
    end

    def self.ui_path(file)
      File.join(SketchDraw::PLUGIN_DIR, 'src', 'ui', file)
    end
  end
end
