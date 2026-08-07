module SketchDraw
  # ── Debug logging ────────────────────────────────────────────────────
  # Toggle with `SketchDraw::Debug.enable` / `.disable` from Ruby Console.
  # Default ON for the Thick+Style diagnostic phase (v5.64+); set to false
  # once the click-to-refresh + broken-dash issues are resolved so normal
  # users don't see console spam.
  module Debug
    # v5.69: default OFF for release builds. Users can enable at any
    # time via Ruby Console: `SketchDraw::Debug.enable`
    @enabled = false
    def self.enable;  @enabled = true;  puts '[SketchDraw::Debug] ON';  end
    def self.disable; @enabled = false; puts '[SketchDraw::Debug] OFF'; end
    def self.on?; @enabled; end
    def self.log(tag, msg)
      return unless @enabled
      puts "[SketchDraw::#{tag}] #{msg}"
    end
  end

  # ── Diagnose command ────────────────────────────────────────────────
  # From Ruby Console: `SketchDraw.diagnose` — dumps overlay state, cache
  # size, thick-edge count, and which tags they sit on. Use when a Thick
  # or Style problem doesn't reveal itself from the runtime logs alone.
  def self.diagnose
    m = Sketchup.active_model
    return puts('[SketchDraw::Diagnose] no active model') unless m
    puts "═══ SketchDraw Diagnose ═══"
    puts "PLUGIN_VER: #{PLUGIN_VER}"
    puts "Model: #{m.title.inspect}   entities: #{m.entities.length}"
    ov_found, ov_enabled = nil, nil
    m.overlays.each do |o|
      if o.respond_to?(:overlay_id) && o.overlay_id == ThicknessOverlay::OVERLAY_ID
        ov_found = true
        ov_enabled = o.respond_to?(:enabled?) ? o.enabled? : nil
      end
    end rescue nil
    puts "Overlay: installed=#{ov_found.inspect} enabled=#{ov_enabled.inspect}"
    thick = 0; thick_styled = 0; thick_on_skd = 0; style_name_seen = {}
    walk = lambda do |ents|
      ents.each do |ent|
        case ent
        when Sketchup::Edge
          mm = ent.get_attribute(PLUGIN_ID, 'line_width_mm').to_f rescue 0
          next unless mm > 0
          thick += 1
          sn = ent.get_attribute(PLUGIN_ID, 'line_style_name') rescue nil
          if sn
            thick_styled += 1
            style_name_seen[sn] ||= 0
            style_name_seen[sn]  += 1
          end
          lay = ent.layer
          thick_on_skd += 1 if lay && lay.name.to_s.start_with?('SKD_Style_')
        when Sketchup::Group
          walk.call(ent.entities)
        when Sketchup::ComponentInstance
          walk.call(ent.definition.entities)
        end
      end
    end
    walk.call(m.entities)
    puts "Thick edges total:         #{thick}"
    puts "  ↳ with line_style_name:  #{thick_styled}"
    puts "  ↳ still on SKD_Style_:   #{thick_on_skd}  #{thick_on_skd > 0 ? '⚠ un-migrated' : '✓'}"
    puts "  ↳ style_name distribution: #{style_name_seen.inspect}"
    puts "═══════════════════════════"
    nil
  end
end

require_relative 'state'
require_relative 'toolbar'
require_relative 'tools/paper_frame'
require_relative 'tools/title_block_editor'
require_relative 'tools/scale_tool'
require_relative 'tools/dimension_tool'
require_relative 'tools/text_tool'
require_relative 'tools/edit_tool'
require_relative 'tools/arrow_tool'
require_relative 'tools/image_import'
require_relative 'tools/pdf_export'
require_relative 'tools/draw_order'
require_relative 'tools/lock_2d'
require_relative 'tools/colour_picker'
require_relative 'tools/colour_overlay'
require_relative 'tools/line_thickness'
require_relative 'tools/line_style'
require_relative 'tools/section_grid'
require_relative 'tools/palette'
require_relative 'tools/snapshot'
require_relative 'tools/hatch'

module SketchDraw
  def self.version_ok?
    Sketchup.version.to_f >= MIN_VERSION
  end

  class ModelObserver < Sketchup::AppObserver
    def onNewModel(model)
      State.load_from_model(model)
      State.remove_native_dim_observer(model)
      # Thickness overlay is installed lazily on models that already have
      # thickness-tagged edges. Colour display is native (EdgeColorMode=1)
      # so no overlay needed for it any more.
      ThicknessOverlayManager.install_if_needed(model)
    end
    def onOpenModel(model)
      State.load_from_model(model)
      State.install_native_dim_observer(model) if State.scale_ratio > 1
      ThicknessOverlayManager.install_if_needed(model)
    end
  end

  def self.boot
    unless version_ok?
      UI.messagebox(
        "SketchDraw requires SketchUp 2019 or later.\nCurrent: #{Sketchup.version}",
        MB_OK
      )
      return
    end
    Toolbar.build
    EditTool.install_observer
    Sketchup.add_observer(ModelObserver.new)
    State.load_from_model
    # Only reinstall the thickness overlay for models that already contain
    # thickness-tagged edges. The check is O(1) (model attribute lookup),
    # so sessions that never used the feature pay nothing.
    ThicknessOverlayManager.install_if_needed(Sketchup.active_model)

    menu = UI.menu('Extensions').add_submenu('SketchDraw')
    menu.add_item('Show Toolbar') { Toolbar.show_toolbar }
  end

  boot
end
