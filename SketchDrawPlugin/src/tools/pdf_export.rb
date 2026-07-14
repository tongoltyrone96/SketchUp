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

      view      = model.active_view
      saved_cam = save_camera(model)

      begin
        require 'tmpdir'

        # Pre-render at current viewport size to upload textures into GPU VRAM before
        # changing the camera — without this, write_image after a zoom change renders
        # textured faces as solid black.
        pre_tmp = File.join(Dir.tmpdir, "skd_pre_#{Time.now.to_i}.jpg")
        view.write_image(filename: pre_tmp, width: view.vpwidth, height: view.vpheight, antialias: false)
        File.delete(pre_tmp) rescue nil

        setup_export_camera(model, frame, paper_w_mm, paper_h_mm)

        px_w     = (paper_w_mm / 25.4 * 210).to_i
        px_h     = (paper_h_mm / 25.4 * 210).to_i
        temp_jpg = pdf_path.sub(/\.pdf$/i, '_tmp.jpg')

        view.write_image(filename: temp_jpg, width: px_w, height: px_h, compression: 0.95, antialias: true)
        raise "view.write_image failed: #{temp_jpg}" unless File.exist?(temp_jpg)

        jpg = File.binread(temp_jpg)
        wpt = (paper_w_mm * 72.0 / 25.4).round(2)
        hpt = (paper_h_mm * 72.0 / 25.4).round(2)

        File.binwrite(pdf_path, build_pdf(jpg, wpt, hpt, px_w, px_h))
        File.delete(temp_jpg) rescue nil

        UI.messagebox("PDF saved to:\n#{pdf_path}", MB_OK)
      rescue => e
        puts "SketchDraw PDF export error: #{e.message}"
        puts e.backtrace.first(5).join("\n")
        UI.messagebox("PDF export error:\n#{e.message}", MB_OK)
      ensure
        restore_camera(model, saved_cam)
      end
    end

    def self.build_pdf(jpg, wpt, hpt, pw, ph)
      o    = {}
      o[1] = "<< /Type /Catalog /Pages 2 0 R >>"
      o[2] = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
      o[3] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{wpt} #{hpt}] " \
             "/Contents 4 0 R /Resources << /XObject << /Im0 5 0 R >> >> >>"
      cs   = "q #{wpt} 0 0 #{hpt} 0 0 cm /Im0 Do Q"
      o[4] = "<< /Length #{cs.bytesize} >>\nstream\n#{cs}\nendstream"
      ih   = "<< /Type /XObject /Subtype /Image /Width #{pw} /Height #{ph} " \
             "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length #{jpg.bytesize} >>"
      buf  = String.new("%PDF-1.4\n", encoding: 'BINARY')
      off  = {}
      [1, 2, 3, 4].each { |n| off[n] = buf.bytesize; buf << "#{n} 0 obj\n#{o[n]}\nendobj\n" }
      off[5] = buf.bytesize
      buf << "5 0 obj\n#{ih}\nstream\n" << jpg << "\nendstream\nendobj\n"
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
      cx = width  / 2.0
      cy = height / 2.0
      camera.set(
        Geom::Point3d.new(cx, cy, 1000),
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
