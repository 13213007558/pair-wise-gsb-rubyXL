module RubyXL
  class Parser
    # Parse <tt>.xlsx</tt> file by reading it from local disk.
    def self.parse(src_file_path, options = nil)
      preserving_extensions(options) do
        begin
          ::Zip::File.open(src_file_path) { |zip_file|
            root = RubyXL::WorkbookRoot.parse_zip_file(zip_file)
            root.source_file_path = src_file_path
            root.workbook
          }
        rescue ::Zip::Error => e
          raise e, "XLSX file format error: #{e}", e.backtrace
        end
      end
    end

    # Parse <tt>.xlsx</tt> file contained in a stream (useful for receiving over HTTP).
    def self.parse_buffer(buffer, options = nil)
      preserving_extensions(options) do
        root = nil
        begin
          ::Zip::File.open_buffer(buffer) { |zip_file|
            root = RubyXL::WorkbookRoot.parse_zip_file(zip_file)
          }
          root.workbook
        rescue ::Zip::Error => e
          raise e, "XLSX file format error: #{e}", e.backtrace
        end
      end
    end

    def self.preserving_extensions(options)
      previous = RubyXL.preserve_extensions
      RubyXL.preserve_extensions = options.is_a?(Hash) ? options.fetch(:preserve_extensions, previous) : !!options
      yield
    ensure
      RubyXL.preserve_extensions = previous
    end
  end
end
