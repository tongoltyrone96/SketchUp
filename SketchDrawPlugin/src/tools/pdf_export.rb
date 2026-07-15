module SketchDraw
  module PdfExport
    ATTR_NS = SketchDraw::PLUGIN_ID

    def self.run
      model = Sketchup.active_model
      return unless SketchDraw.version_ok?

      frame = PaperFrame.find_frame(model)
      unless frame
        UI.messagebox('No paper frame found. Please insert a paper frame first (Paper button).', MB_OK)
        return
      end

      pdf_path = UI.savepanel('Export PDF', '', 'PDF Files|*.pdf||')
      return unless pdf_path
      pdf_path += '.pdf' unless pdf_path.end_with?('.pdf')

      paper_w_mm = frame.get_attribute(ATTR_NS, 'width').to_f
      paper_h_mm = frame.get_attribute(ATTR_NS, 'height').to_f

      # Show progress dialog — centered on screen, slightly larger
      prog = UI::HtmlDialog.new(
        dialog_title: 'SketchDraw — PDF Export',
        width: 400, height: 130,
        left: 560, top: 420,
        resizable: false, scrollable: false,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      prog.set_html(<<~HTML)
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          * { margin:0; padding:0; box-sizing:border-box; }
          body { background:#1e1e1e; color:#fff; font-family:Arial,sans-serif;
                 display:flex; align-items:center; justify-content:center;
                 height:100vh; text-align:center; }
          .msg { font-size:15px; font-weight:bold; }
          .sub { font-size:12px; opacity:0.6; margin-top:8px; }
          .dots { display:inline-block; animation:dot 1.2s infinite; }
          @keyframes dot {
            0%{content:'.'} 33%{content:'..'} 66%{content:'...'} 100%{content:'.'}
          }
        </style></head>
        <body>
          <div>
            <div class="msg">Exporting PDF<span class="dots">...</span></div>
            <div class="sub">Please wait — this may take a few seconds</div>
          </div>
        </body></html>
      HTML
      prog.show

      # Delay export 300ms so the dialog has time to appear before SketchUp blocks
      UI.start_timer(0.3, false) do
        perform_export(model, frame, pdf_path, paper_w_mm, paper_h_mm, prog)
      end
    end

    # ── Main export logic ─────────────────────────────────────────────
    def self.perform_export(model, frame, pdf_path, paper_w_mm, paper_h_mm, prog)
      view        = model.active_view
      saved_cam   = save_camera(model)
      saved_shad  = save_shadow_info(model)

      begin
        require 'tmpdir'
        require 'zlib'

        # Pre-render at current viewport to load textures into GPU VRAM
        pre_tmp = File.join(Dir.tmpdir, "skd_pre_#{Time.now.to_i}.png")
        view.write_image(filename: pre_tmp, width: view.vpwidth, height: view.vpheight, antialias: false)
        File.delete(pre_tmp) rescue nil

        setup_export_camera(model, frame, paper_w_mm, paper_h_mm)

        # Disable sun shading so face colors render as true material colors
        apply_export_shadow_settings(model)

        # Clear selection so blue highlight doesn't appear in the exported image
        saved_sel = model.selection.to_a
        model.selection.clear

        long_mm  = [paper_w_mm, paper_h_mm].max
        long_in  = long_mm / 25.4
        base_dpi = long_mm <= 420 ? 600 : 300
        cap_dpi  = (10_000.0 / long_in).floor
        dpi      = [[base_dpi, cap_dpi].min, 150].max
        px_w    = (paper_w_mm / 25.4 * dpi).to_i
        px_h    = (paper_h_mm / 25.4 * dpi).to_i

        Sketchup.set_status_text("SketchDraw: rendering #{px_w}x#{px_h} px (#{dpi} DPI)...")

        temp_png = pdf_path.sub(/\.pdf$/i, '_tmp.png')
        view.write_image(filename: temp_png, width: px_w, height: px_h, antialias: true)
        raise "view.write_image failed: #{temp_png}" unless File.exist?(temp_png)

        Sketchup.set_status_text('SketchDraw: building PDF (lossless)...')

        raw_rgb = png_to_raw_rgb(temp_png, px_w, px_h)
        File.delete(temp_png) rescue nil

        wpt = (paper_w_mm * 72.0 / 25.4).round(2)
        hpt = (paper_h_mm * 72.0 / 25.4).round(2)

        File.binwrite(pdf_path, build_pdf(raw_rgb, wpt, hpt, px_w, px_h))
        Sketchup.set_status_text('')
        prog.close rescue nil
        model.selection.add(saved_sel) rescue nil
        UI.messagebox("PDF saved to:\n#{pdf_path}", MB_OK)
      rescue => e
        Sketchup.set_status_text('')
        prog.close rescue nil
        puts "SketchDraw PDF export error: #{e.message}"
        puts e.backtrace.first(5).join("\n")
        UI.messagebox("PDF export error:\n#{e.message}", MB_OK)
      ensure
        restore_shadow_info(model, saved_shad)
        restore_camera(model, saved_cam)
        model.selection.add(saved_sel) rescue nil
      end
    end
    private_class_method :perform_export

    # ── Render options helpers ────────────────────────────────────────
    def self.save_render_options(model)
      ro = model.rendering_options
      saved = {}
      %w[DisplayShadows DisplayFog DisplaySky DisplayGround BackgroundColor
         DrawSilhouettes Profiles SilhouetteEdges].each do |k|
        begin; saved[k] = ro[k]; rescue; end
      end
      saved
    end
    private_class_method :save_render_options

    def self.apply_export_render_options(model)
      ro = model.rendering_options
      {
        'DisplayShadows'  => false,
        'DisplayFog'      => false,
        'DisplaySky'      => false,
        'DisplayGround'   => false,
        'BackgroundColor' => Sketchup::Color.new(255, 255, 255),
        'DrawSilhouettes' => true,
        'Profiles'        => 2,
        'SilhouetteEdges' => 2
      }.each do |key, val|
        begin
          ro[key] = val
        rescue => e
          puts "SketchDraw render option '#{key}' skipped: #{e.message}"
        end
      end
    end
    private_class_method :apply_export_render_options

    def self.restore_render_options(model, saved)
      ro = model.rendering_options
      saved.each do |k, v|
        begin
          ro[k] = v
        rescue
        end
      end
    end
    private_class_method :restore_render_options

    # ── Shadow info helpers (safe alternative to rendering_options) ───
    def self.save_shadow_info(model)
      si = model.shadow_info
      {
        'DisplayShadows'      => si['DisplayShadows'],
        'UseSunForAllShading' => si['UseSunForAllShading']
      }
    rescue
      {}
    end
    private_class_method :save_shadow_info

    def self.apply_export_shadow_settings(model)
      si = model.shadow_info
      begin; si['DisplayShadows']      = false; rescue; end
      begin; si['UseSunForAllShading'] = false; rescue; end
    end
    private_class_method :apply_export_shadow_settings

    def self.restore_shadow_info(model, saved)
      si = model.shadow_info
      saved.each do |k, v|
        begin; si[k] = v; rescue; end
      end
    end
    private_class_method :restore_shadow_info

    # ── PNG decoder: raw RGB bytes ────────────────────────────────────
    def self.png_to_raw_rgb(path, pw, ph)
      require 'zlib'
      data     = File.binread(path)
      pos      = 8
      idat     = String.new('', encoding: 'BINARY')
      channels = 3

      while pos < data.bytesize
        len  = data[pos, 4].unpack1('N')
        type = data[pos + 4, 4]
        if type == 'IHDR'
          color_type = data[pos + 8 + 9, 1].unpack1('C')
          channels   = (color_type == 6 || color_type == 4) ? 4 : 3
        end
        idat << data[pos + 8, len] if type == 'IDAT'
        pos += 12 + len
      end

      raw    = Zlib::Inflate.inflate(idat)
      stride = pw * channels
      out    = String.new('', encoding: 'BINARY')
      prev   = "\x00".b * stride

      ph.times do |y|
        base   = y * (stride + 1)
        filter = raw.getbyte(base)
        row    = raw[base + 1, stride].bytes

        case filter
        when 1
          stride.times { |i| row[i] = (row[i] + (i >= channels ? row[i - channels] : 0)) & 0xFF }
        when 2
          pb = prev.bytes
          stride.times { |i| row[i] = (row[i] + pb[i]) & 0xFF }
        when 3
          pb = prev.bytes
          stride.times { |i|
            a = i >= channels ? row[i - channels] : 0
            row[i] = (row[i] + ((a + pb[i]) >> 1)) & 0xFF
          }
        when 4
          pb = prev.bytes
          stride.times { |i|
            a  = i >= channels ? row[i - channels] : 0
            b  = pb[i]
            c  = i >= channels ? pb[i - channels] : 0
            p2 = a + b - c
            pa = (p2 - a).abs; pb2 = (p2 - b).abs; pc = (p2 - c).abs
            pr = pa <= pb2 && pa <= pc ? a : pb2 <= pc ? b : c
            row[i] = (row[i] + pr) & 0xFF
          }
        end

        prev = row.pack('C*')
        if channels == 4
          rgb = String.new('', encoding: 'BINARY')
          pw.times { |i| rgb << prev[i * 4, 3] }
          out << rgb
        else
          out << prev
        end
      end
      out
    end
    private_class_method :png_to_raw_rgb

    def self.build_pdf(rgb, wpt, hpt, pw, ph)
      require 'zlib'
      compressed = Zlib::Deflate.deflate(rgb, Zlib::BEST_COMPRESSION)

      o    = {}
      o[1] = "<< /Type /Catalog /Pages 2 0 R >>"
      o[2] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
      o[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{wpt} #{hpt}] " \
             "/Contents 4 0 R /Resources << /XObject << /Im0 5 0 R >> >> >>"
      cs   = "q #{wpt} 0 0 #{hpt} 0 0 cm /Im0 Do Q"
      o[4] = "<< /Length #{cs.bytesize} >>\nstream\n#{cs}\nendstream"
      ih   = "<< /Type /XObject /Subtype /Image /Width #{pw} /Height #{ph} " \
             "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode " \
             "/Length #{compressed.bytesize} >>"

      buf = String.new("%PDF-1.4\n", encoding: 'BINARY')
      off = {}
      [1, 2, 3, 4].each { |n| off[n] = buf.bytesize; buf << "#{n} 0 obj\n#{o[n]}\nendobj\n" }
      off[5] = buf.bytesize
      buf << "5 0 obj\n#{ih}\nstream\n" << compressed << "\nendstream\nendobj\n"
      xp = buf.bytesize
      buf << "xref\n0 6\n0000000000 65535 f \n"
      (1..5).each { |n| buf << sprintf("%010d 00000 n \n", off[n]) }
      buf << "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{xp}\n%%EOF\n"
      buf
    end
    private_class_method :build_pdf

    def self.setup_export_camera(model, frame, width, height)
      view   = model.active_view
      camera = view.camera
      camera.perspective = false
      cx = width.mm  / 2.0
      cy = height.mm / 2.0
      camera.set(
        Geom::Point3d.new(cx, cy, 1000.mm),
        Geom::Point3d.new(cx, cy, 0),
        Geom::Vector3d.new(0, 1, 0)
      )
      frame && frame.valid? ? view.zoom(frame) : view.zoom_extents
    end
    private_class_method :setup_export_camera

    def self.save_camera(model)
      cam = model.active_view.camera
      { eye: cam.eye.clone, target: cam.target.clone, up: cam.up.clone, perspective: cam.perspective? }
    end
    private_class_method :save_camera

    def self.restore_camera(model, saved)
      return unless saved
      cam = model.active_view.camera
      cam.set(saved[:eye], saved[:target], saved[:up])
      cam.perspective = saved[:perspective]
    end
    private_class_method :restore_camera
  end
end
