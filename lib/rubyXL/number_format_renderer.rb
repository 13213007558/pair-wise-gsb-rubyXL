require 'bigdecimal'
require 'date'

module RubyXL
  # Pure-Ruby renderer for OOXML number format codes (the +formatCode+
  # attribute of +numFmt+). Given a raw cell value and a format code it
  # produces the text a spreadsheet application would display, plus the font
  # color (if any) requested by the format itself.
  #
  # The caller must explicitly provide:
  #
  # * +locale+ - a locale tag (+en-US+, +de-DE+, +zh-CN+, +ja-JP+ are built
  #   in) or a Hash with locale data (see LOCALES for the expected keys).
  # * +date_system+ - +:excel_1900+ (default Excel/Windows epoch) or
  #   +:excel_1904+ (legacy Mac epoch).
  #
  # == Date systems and the 1900 leap year bug
  #
  # * +:excel_1900+ - serial 1 is 1900-01-01. For compatibility with the
  #   historic Lotus 1-2-3 bug that Excel deliberately preserves, serial 60
  #   maps to the fictitious date 1900-02-29, and serials greater than 60 are
  #   shifted by one day relative to the proleptic Gregorian calendar
  #   (serial 61 is 1900-03-01). As a further consequence, weekdays for
  #   serials below 61 are off by one from the real calendar (Excel shows
  #   serial 1 as a Sunday); this renderer reproduces that behavior.
  # * +:excel_1904+ - serial 0 is 1904-01-01; no leap year quirk applies.
  #
  # == Rounding
  #
  # All numeric rounding is performed with BigDecimal on the shortest
  # round-trip decimal representation of the input, rounding half away from
  # zero (matching Excel display behavior). The value is never round-tripped
  # through a low-precision string (e.g. sprintf %g) and then zero-padded.
  #
  # == Unsupported constructs
  #
  # Constructs that cannot be resolved locally - in-format locale/currency
  # directives ([$-409], [$EUR-407]), [DBNumN]/[NatNum] modifiers, unknown
  # locale tags, and negative date serials - make +render+ return a Failure
  # with a structured reason instead of silently passing the raw value
  # through as if it were the formatted result.
  module NumberFormatRenderer
    SECTION_COLORS = {
      'black'   => :black,   'white' => :white, 'red'    => :red,
      'green'   => :green,   'blue'  => :blue,  'yellow' => :yellow,
      'magenta' => :magenta, 'cyan'  => :cyan,
    }.freeze

    CONDITION_OPERATORS = ['<=', '>=', '<>', '=', '<', '>'].freeze

    BUILTIN_FORMATS = {
      0  => 'General',
      14 => 'm/d/yyyy',
      22 => 'm/d/yy h:mm',
    }.freeze

    LOCALES = {
      'en-US' => {
        'decimal_separator'       => '.',
        'thousands_separator'     => ',',
        'month_names'             => %w[January February March April May June July
                                        August September October November December],
        'abbreviated_month_names' => %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec],
        'weekday_names'           => %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday],
        'abbreviated_weekday_names' => %w[Sun Mon Tue Wed Thu Fri Sat],
        'am' => 'AM', 'pm' => 'PM', 'a' => 'A', 'p' => 'P',
      },
      'de-DE' => {
        'decimal_separator'       => ',',
        'thousands_separator'     => '.',
        'month_names'             => %w[Januar Februar März April Mai Juni Juli
                                        August September Oktober November Dezember],
        'abbreviated_month_names' => %w[Jan Feb Mär Apr Mai Jun Jul Aug Sep Okt Nov Dez],
        'weekday_names'           => %w[Sonntag Montag Dienstag Mittwoch Donnerstag Freitag Samstag],
        'abbreviated_weekday_names' => %w[So Mo Di Mi Do Fr Sa],
        'am' => 'AM', 'pm' => 'PM', 'a' => 'A', 'p' => 'P',
      },
      'zh-CN' => {
        'decimal_separator'       => '.',
        'thousands_separator'     => ',',
        'month_names'             => %w[一月 二月 三月 四月 五月 六月 七月 八月 九月 十月 十一月 十二月],
        'abbreviated_month_names' => %w[1月 2月 3月 4月 5月 6月 7月 8月 9月 10月 11月 12月],
        'weekday_names'           => %w[星期日 星期一 星期二 星期三 星期四 星期五 星期六],
        'abbreviated_weekday_names' => %w[周日 周一 周二 周三 周四 周五 周六],
        'am' => '上午', 'pm' => '下午', 'a' => '上', 'p' => '下',
      },
      'ja-JP' => {
        'decimal_separator'       => '.',
        'thousands_separator'     => ',',
        'month_names'             => %w[1月 2月 3月 4月 5月 6月 7月 8月 9月 10月 11月 12月],
        'abbreviated_month_names' => %w[1月 2月 3月 4月 5月 6月 7月 8月 9月 10月 11月 12月],
        'weekday_names'           => %w[日曜日 月曜日 火曜日 水曜日 木曜日 金曜日 土曜日],
        'abbreviated_weekday_names' => %w[日 月 火 水 木 金 土],
        'am' => '午前', 'pm' => '午後', 'a' => '午', 'p' => '午',
      },
    }.freeze

    # Successful rendering result.
    class Result
      attr_reader :text, :color, :section_index, :type, :format_code

      def initialize(text:, color:, section_index:, type:, format_code:)
        @text = text
        @color = color
        @section_index = section_index
        @type = type
        @format_code = format_code
      end

      def ok?
        true
      end
    end

    # Structured failure: the format could not be rendered locally.
    class Failure
      attr_reader :reason, :detail, :directive, :format_code

      def initialize(reason:, detail:, format_code:, directive: nil)
        @reason = reason
        @detail = detail
        @directive = directive
        @format_code = format_code
      end

      def ok?
        false
      end
    end

    # Internal representation of one format section (text between ';').
    class Section
      attr_accessor :color, :condition_operator, :condition_value,
                    :unsupported_directive, :has_text_placeholder,
                    :percent_count, :scaling_commas, :thousands_separator,
                    :elapsed_letter, :fraction_separator, :date, :fixed_denominator
      attr_reader :tokens

      def initialize
        @tokens = []
        @percent_count = 0
        @scaling_commas = 0
        @thousands_separator = false
        @fraction_separator = false
        @date = false
      end

      def date?
        @date
      end
    end

    class << self
      # Render +value+ according to +format_code+. +format_code+ may be a
      # String, an Integer builtin format id, or a RubyXL::NumberFormat.
      # Returns a Result on success and a Failure otherwise.
      def render(value, format_code, locale: 'en-US', date_system: :excel_1900)
        code = resolve_format_code(format_code)
        return code if code.is_a?(Failure)

        locale_data = resolve_locale(locale, code)
        return locale_data if locale_data.is_a?(Failure)

        unless [:excel_1900, :excel_1904].include?(date_system)
          return Failure.new(:reason => :invalid_date_system,
                             :detail => "date_system must be :excel_1900 or :excel_1904, got #{date_system.inspect}",
                             :format_code => code)
        end

        sections = split_sections(code).map { |raw| parse_section(raw) }
        unsupported = sections.find { |s| !s.unsupported_directive.nil? }
        unless unsupported.nil?
          directive = unsupported.unsupported_directive
          return Failure.new(:reason => :unsupported_locale_directive,
                             :detail => "format directive #{directive} requires locale, calendar or currency data that is not available offline",
                             :directive => directive, :format_code => code)
        end

        return render_general(value, locale_data, code) if code.strip.casecmp('General').zero?

        section, section_index = select_section(sections, value)

        if value.nil?
          return Result.new(:text => '', :color => nil, :section_index => section_index,
                            :type => :general, :format_code => code)
        end

        if value == true || value == false
          return Result.new(:text => value.to_s.upcase, :color => nil,
                            :section_index => section_index, :type => :general,
                            :format_code => code)
        end

        unless value.is_a?(Numeric)
          text = section.nil? ? value.to_s : render_text_section(section, value.to_s)
          return Result.new(:text => text, :color => section && section.color,
                            :section_index => section_index, :type => :text,
                            :format_code => code)
        end

        if section.date?
          if negative_value?(value)
            return Failure.new(:reason => :negative_date_serial,
                               :detail => "negative serial #{value.inspect} cannot be displayed as a date (Excel shows ####)",
                               :format_code => code)
          end
          text = render_date(section, value, date_system, locale_data)
          return Result.new(:text => text, :color => section.color,
                            :section_index => section_index, :type => :date,
                            :format_code => code)
        end

        unless number_body?(section)
          return Result.new(:text => render_literal_section(section), :color => section.color,
                            :section_index => section_index, :type => :number,
                            :format_code => code)
        end

        auto_sign = sections.length == 1 || sections.any? { |s| !s.condition_operator.nil? }
        value = value.to_f if value.is_a?(Rational)
        text = render_number(section, value, locale_data, auto_sign)
        Result.new(:text => text, :color => section.color,
                   :section_index => section_index, :type => :number,
                   :format_code => code)
      end

      private

      # Note: Float#negative? is false for -0.0, so the sign bit of a
      # negative zero is detected through its reciprocal instead.
      def negative_value?(value)
        return true if value < 0

        value.is_a?(Float) && value.zero? && (1.0 / value).negative?
      end

      def resolve_format_code(format_code)
        case format_code
        when String
          format_code
        when Integer
          code = BUILTIN_FORMATS[format_code]
          return code unless code.nil?

          Failure.new(:reason => :unknown_builtin_format_id,
                      :detail => "no built-in format code known for id #{format_code}",
                      :format_code => format_code.to_s)
        else
          if format_code.respond_to?(:format_code)
            format_code.format_code
          else
            Failure.new(:reason => :invalid_format_code,
                        :detail => "cannot derive a format code from #{format_code.inspect}",
                        :format_code => format_code.to_s)
          end
        end
      end

      def resolve_locale(locale, code)
        case locale
        when Hash
          locale
        when String, Symbol
          data = LOCALES[locale.to_s]
          return data unless data.nil?

          Failure.new(:reason => :unsupported_locale,
                      :detail => "no built-in locale data for #{locale.inspect}; pass a locale data Hash instead",
                      :format_code => code)
        else
          Failure.new(:reason => :unsupported_locale,
                      :detail => "locale must be a tag or a data Hash, got #{locale.inspect}",
                      :format_code => code)
        end
      end

      # Split a format code into its (up to four) sections, honoring quoted
      # strings, escaped characters and bracketed directives.
      def split_sections(code)
        sections = []
        buf = +''
        i = 0
        while i < code.length
          ch = code[i]
          case ch
          when '"'
            j = code.index('"', i + 1) || code.length
            buf << code[i..j]
            i = j + 1
          when '\\', '_', '*'
            buf << code[i, 2].to_s
            i += 2
          when '['
            j = code.index(']', i) || code.length
            buf << code[i..j]
            i = j + 1
          when ';'
            sections << buf
            buf = +''
            i += 1
          else
            buf << ch
            i += 1
          end
        end
        sections << buf
        sections.first(4)
      end

      def select_section(sections, value)
        unless value.is_a?(Numeric)
          if sections.length >= 4
            return [sections[3], 3]
          elsif sections.length == 1 && sections[0].has_text_placeholder
            return [sections[0], 0]
          else
            return [nil, nil]
          end
        end

        if sections.any? { |s| !s.condition_operator.nil? }
          sections.each_with_index do |s, i|
            next if s.condition_operator.nil?
            return [s, i] if condition_match?(s, value)
          end
          idx = sections.index { |s| s.condition_operator.nil? }
          return [sections[idx], idx] unless idx.nil?
          return [sections[0], 0]
        end

        case sections.length
        when 1
          [sections[0], 0]
        when 2
          negative_value?(value) ? [sections[1], 1] : [sections[0], 0]
        else
          if negative_value?(value)
            [sections[1], 1]
          elsif value == 0
            [sections[2], 2]
          else
            [sections[0], 0]
          end
        end
      end

      def condition_match?(section, value)
        target = section.condition_value
        case section.condition_operator
        when '<=' then value <= target
        when '>=' then value >= target
        when '<>' then value != target
        when '='  then value == target
        when '<'  then value < target
        when '>'  then value > target
        else false
        end
      end

      def parse_section(raw)
        section = Section.new
        body, elapsed_tokens = extract_brackets(raw, section)
        section.tokens.concat(elapsed_tokens)
        tokenize(body, section)
        classify(section)
        section
      end

      # Pull [...] directives out of the section body. Returns the remaining
      # body plus any elapsed-time tokens ([h], [m], [s]) in order.
      def extract_brackets(raw, section)
        body = +''
        elapsed = []
        i = 0
        while i < raw.length
          ch = raw[i]
          if ch == '"'
            j = raw.index('"', i + 1) || raw.length
            body << raw[i..j]
            i = j + 1
          elsif ch == '[' && (j = raw.index(']', i))
            content = raw[(i + 1)...j]
            token = handle_bracket(content, section)
            elapsed << token unless token.nil?
            i = j + 1
          else
            body << ch
            i += 1
          end
        end
        [body, elapsed]
      end

      def handle_bracket(content, section)
        downcased = content.downcase

        operator = CONDITION_OPERATORS.find { |op| content.start_with?(op) }
        unless operator.nil?
          begin
            section.condition_operator = operator
            section.condition_value = Float(content[operator.length..].strip)
          rescue ArgumentError
            section.unsupported_directive = "[#{content}]"
          end
          return nil
        end

        if SECTION_COLORS.key?(downcased)
          section.color = SECTION_COLORS[downcased]
          return nil
        end

        if downcased.start_with?('color') && downcased[5..].strip =~ /\A\d+\z/
          section.color = "color_#{downcased[5..].strip}".to_sym
          return nil
        end

        letters = downcased.chars
        if !letters.empty? && letters.all? { |c| c == letters[0] } && 'hms'.include?(letters[0])
          section.elapsed_letter = letters[0]
          return [:elapsed, letters[0], letters.length]
        end

        # [$-409], [$EUR-407], [DBNum1], [NatNum] and anything else we
        # cannot resolve offline.
        section.unsupported_directive = "[#{content}]"
        nil
      end

      def tokenize(body, section)
        i = 0
        while i < body.length
          ch = body[i]
          case ch
          when '"'
            j = body.index('"', i + 1) || body.length
            section.tokens << [:literal, body[(i + 1)...j].to_s]
            i = j + 1
          when '\\'
            section.tokens << [:literal, body[i + 1].to_s]
            i += 2
          when '_'
            section.tokens << [:skip, body[i + 1].to_s]
            i += 2
          when '*'
            section.tokens << [:fill, body[i + 1].to_s]
            i += 2
          when '@'
            section.has_text_placeholder = true
            section.tokens << [:text_placeholder]
            i += 1
          when '%'
            section.percent_count += 1
            section.tokens << [:literal, '%']
            i += 1
          when '0', '#', '?'
            j = i
            j += 1 while j < body.length && body[j] == ch
            section.tokens << [:digit, ch, j - i]
            i = j
          when ','
            section.tokens << [:comma]
            i += 1
          when '.'
            section.tokens << [:decimal_point]
            i += 1
          when '/'
            section.tokens << [:slash]
            i += 1
          when 'E', 'e'
            nxt = body[i + 1]
            if nxt == '+' || nxt == '-'
              section.tokens << [:exp, nxt]
              i += 2
            else
              section.tokens << [:literal, ch]
              i += 1
            end
          when 'A', 'a'
            if body[i, 5].to_s.casecmp('AM/PM').zero?
              section.tokens << [:ampm, 'AM/PM']
              i += 5
            elsif body[i, 3].to_s.casecmp('A/P').zero?
              section.tokens << [:ampm, 'A/P']
              i += 3
            else
              section.tokens << [:literal, ch]
              i += 1
            end
          when 'y', 'Y', 'm', 'M', 'd', 'D', 'h', 'H', 's', 'S'
            letter = ch.downcase
            j = i
            j += 1 while j < body.length && body[j].downcase == letter
            section.tokens << [:date_part, letter, j - i]
            i = j
          else
            section.tokens << [:literal, ch]
            i += 1
          end
        end
      end

      def classify(section)
        tokens = section.tokens
        has_exp = tokens.any? { |t| t[0] == :exp }
        slash_index = tokens.index { |t| t[0] == :slash }
        has_date = tokens.any? { |t| [:date_part, :elapsed, :ampm].include?(t[0]) }

        fraction = false
        if !has_exp && !slash_index.nil?
          fraction = tokens[(slash_index + 1)..].any? { |t|
            t[0] == :digit || (t[0] == :literal && digit_string?(t[1]))
          }
        end

        section.date = has_date && !has_exp && !fraction
        section.fraction_separator = fraction

        if section.date?
          remap_minutes(section)
          detect_subseconds(section)
          section.tokens.map! do |t|
            case t[0]
            when :comma then [:literal, ',']
            when :slash then [:literal, '/']
            when :decimal_point then [:literal, '.']
            else t
            end
          end
        else
          process_commas(section)
          consume_fraction_denominator_literals(section) if section.fraction_separator
        end
      end

      def digit_string?(str)
        !str.empty? && str.chars.all? { |c| ('0'..'9').include?(c) }
      end

      # An 'm' is a minute only when it directly follows an hour token or
      # directly precedes a second token; otherwise it is a month.
      def remap_minutes(section)
        tokens = section.tokens
        tokens.each_with_index do |t, i|
          next unless t[0] == :date_part && t[1] == 'm'

          prev = tokens[0...i].reverse.find { |x| [:date_part, :elapsed].include?(x[0]) }
          nxt = tokens[(i + 1)..].find { |x| [:date_part, :elapsed].include?(x[0]) }
          if (!prev.nil? && prev[1] == 'h') || (!nxt.nil? && nxt[1] == 's')
            t[1] = 'n'
          end
        end
      end

      # A comma between digit placeholders is a thousands separator; commas
      # after the last digit placeholder scale the value by 1000 each.
      def process_commas(section)
        tokens = section.tokens
        replacements = {}
        tokens.each_with_index do |t, i|
          next unless t[0] == :comma

          j = i - 1
          j -= 1 while j >= 0 && tokens[j][0] == :comma
          prev = j >= 0 ? tokens[j] : nil

          k = i + 1
          k += 1 while k < tokens.length && tokens[k][0] == :comma
          nxt = k < tokens.length ? tokens[k] : nil

          if !prev.nil? && prev[0] == :digit && !nxt.nil? && nxt[0] == :digit
            section.thousands_separator = true
            replacements[i] = [:consumed]
          elsif !prev.nil? && prev[0] == :digit
            section.scaling_commas += 1
            replacements[i] = [:consumed]
          else
            replacements[i] = [:literal, ',']
          end
        end
        replacements.each { |i, t| tokens[i] = t }
      end

      # In a fraction with a fixed denominator (e.g. "# ?/8") the denominator
      # digits are literals: capture the value and consume them so they are
      # not emitted again during assembly.
      def consume_fraction_denominator_literals(section)
        tokens = section.tokens
        slash_index = tokens.index { |t| t[0] == :slash }
        return if slash_index.nil?

        literal = tokens[(slash_index + 1)..].select { |t| t[0] == :literal }.map { |t| t[1] }.join
        section.fixed_denominator = literal.to_i if !literal.empty? && digit_string?(literal)

        tokens.each_with_index do |t, i|
          next unless i > slash_index && t[0] == :literal && digit_string?(t[1])

          tokens[i] = [:consumed]
        end
      end

      def digit_chars(tokens)
        tokens.select { |t| t[0] == :digit }.flat_map { |t| [t[1]] * t[2] }
      end

      # A decimal point right after a seconds token introduces fractional
      # second digits; mark those digit tokens as consumed.
      def detect_subseconds(section)
        tokens = section.tokens
        tokens.each_with_index do |t, i|
          next unless t[0] == :decimal_point

          prev = tokens[0...i].reverse.find { |x| [:date_part, :elapsed].include?(x[0]) }
          nxt = tokens[i + 1]
          if !prev.nil? && prev[1] == 's' && !nxt.nil? && nxt[0] == :digit && nxt[1] == '0'
            tokens[i] = [:subsecond, nxt[2]]
            tokens[i + 1] = [:consumed]
          end
        end
      end

      def number_body?(section)
        section.tokens.any? { |t| [:digit, :comma, :decimal_point, :slash, :exp].include?(t[0]) }
      end

      def render_number(section, value, locale_data, auto_sign)
        negative = negative_value?(value)
        magnitude = BigDecimal(value.to_s).abs
        magnitude *= (100**section.percent_count) if section.percent_count > 0
        magnitude /= (1000**section.scaling_commas) if section.scaling_commas > 0

        if section.fraction_separator
          body = render_fraction(section, magnitude)
          text = assemble_body(section, body, true)
        elsif section.tokens.any? { |t| t[0] == :exp }
          text = assemble_body(section, render_scientific(section, magnitude, locale_data))
        else
          text = assemble_body(section, render_decimal(section, magnitude, locale_data))
        end

        negative && auto_sign ? "-#{text}" : text
      end

      # Emit the formatted number body at the position of the first numeric
      # token, keeping surrounding literals in place.
      # Literals between the first and last numeric token are considered part
      # of the body itself when +skip_internal+ is set (fractions render
      # their own internal spacing).
      def assemble_body(section, body, skip_internal = false)
        numeric = section.tokens.each_index.select { |i|
          [:digit, :comma, :decimal_point, :slash, :exp].include?(section.tokens[i][0])
        }
        first = numeric.first || -1
        last = numeric.last || -1

        out = +''
        emitted = false
        section.tokens.each_with_index do |t, i|
          case t[0]
          when :literal
            out << t[1] unless skip_internal && i > first && i < last
          when :digit, :comma, :decimal_point, :slash, :exp
            unless emitted
              out << body
              emitted = true
            end
          end
        end
        out
      end

      def render_decimal(section, magnitude, locale_data)
        int_tokens = []
        frac_tokens = []
        target = int_tokens
        section.tokens.each do |t|
          case t[0]
          when :decimal_point
            target = frac_tokens
          when :digit
            t[2].times { target << t[1] }
          end
        end

        rounded = magnitude.round(frac_tokens.length, :half_up)
        int_str, frac_str = rounded.to_s('F').split('.')
        frac_str ||= ''

        int_display = build_int(int_str, int_tokens)
        if section.thousands_separator
          int_display = group_digits(int_display, locale_data['thousands_separator'])
        end
        return int_display if frac_tokens.empty? && section.tokens.none? { |t| t[0] == :decimal_point }

        frac_display = build_frac(frac_str, frac_tokens)
        "#{int_display}#{locale_data['decimal_separator']}#{frac_display}"
      end

      def build_int(int_str, int_tokens)
        digits = int_str == '0' ? '' : int_str
        forced = int_str == '0' && int_tokens.include?('0')
        out = []
        di = digits.length - 1
        int_tokens.reverse_each do |t|
          if di >= 0
            out.unshift(digits[di])
            di -= 1
          else
            case t
            when '0' then out.unshift('0')
            when '?' then out.unshift(' ')
            end
          end
        end
        out.unshift(digits[0..di]) if di >= 0
        result = out.join
        result.empty? && forced ? '0' : result
      end

      def build_frac(frac_str, frac_tokens)
        return '' if frac_tokens.empty?

        padded = frac_str.ljust(frac_tokens.length, '0')
        significant = padded.length
        significant -= 1 while significant > 0 && padded[significant - 1] == '0'
        minimum = frac_tokens.count('0')

        out = +''
        frac_tokens.each_with_index do |t, i|
          if i < minimum || i < significant
            out << padded[i]
          elsif t == '?'
            out << ' '
          end
        end
        out
      end

      def group_digits(int_str, separator)
        i = 0
        i += 1 while i < int_str.length && int_str[i] == ' '
        prefix = int_str[0...i]
        digits = int_str[i..]
        grouped = +''
        digits.reverse.each_char.with_index do |c, idx|
          grouped = c + grouped
          grouped = separator + grouped if ((idx + 1) % 3).zero? && idx + 1 < digits.length
        end
        prefix + grouped
      end

      def render_scientific(section, magnitude, locale_data)
        tokens = section.tokens
        exp_index = tokens.index { |t| t[0] == :exp }
        exp_sign = tokens[exp_index][1]
        exp_width = tokens[(exp_index + 1)..].select { |t| t[0] == :digit }.sum { |t| t[2] }

        int_tokens = []
        frac_tokens = []
        target = int_tokens
        tokens[0...exp_index].each do |t|
          case t[0]
          when :decimal_point then target = frac_tokens
          when :digit then t[2].times { target << t[1] }
          end
        end

        if magnitude.zero?
          exponent = 0
          mantissa = BigDecimal(0)
        else
          exponent = magnitude.exponent - 1
          mantissa = (magnitude / (BigDecimal(10)**exponent)).round(frac_tokens.length, :half_up)
          if mantissa >= 10
            mantissa /= 10
            exponent += 1
          end
        end

        int_str, frac_str = mantissa.round(frac_tokens.length, :half_up).to_s('F').split('.')
        mantissa_str = build_int(int_str, int_tokens)
        unless frac_tokens.empty?
          mantissa_str = "#{mantissa_str}#{locale_data['decimal_separator']}#{build_frac(frac_str || '', frac_tokens)}"
        end

        sign = exponent.negative? ? '-' : (exp_sign == '+' ? '+' : '')
        "#{mantissa_str}E#{sign}#{exponent.abs.to_s.rjust(exp_width, '0')}"
      end

      def render_fraction(section, magnitude)
        tokens = section.tokens
        slash_index = tokens.index { |t| t[0] == :slash }

        num_tokens = []
        i = slash_index - 1
        while i >= 0 && tokens[i][0] == :digit
          num_tokens.unshift(*([tokens[i][1]] * tokens[i][2]))
          i -= 1
        end
        whole_tokens = i >= 0 ? digit_chars(tokens[0..i]) : []

        den_tokens = digit_chars(tokens[(slash_index + 1)..])
        fixed_den = section.fixed_denominator

        if fixed_den.nil?
          max_denominator = (10**den_tokens.length) - 1
          numerator, denominator = best_fraction(magnitude, max_denominator)
        else
          denominator = fixed_den
          numerator = (magnitude * denominator).round(0, :half_up).to_i
        end

        if whole_tokens.empty?
          whole = 0
          remainder = numerator
        else
          whole = numerator / denominator
          remainder = numerator % denominator
        end

        if remainder.zero?
          whole_str = whole_tokens.empty? ? numerator.to_s : build_int(whole.to_s, whole_tokens)
          return whole_str.strip.empty? ? '0' : whole_str
        end

        num_str = build_int(remainder.to_s, num_tokens)
        den_str = denominator.to_s
        if den_tokens.include?('0')
          den_str = den_str.rjust(den_tokens.length, '0')
        elsif den_tokens.include?('?')
          den_str = den_str.ljust(den_tokens.length, ' ')
        end

        return "#{num_str}/#{den_str}" if whole_tokens.empty?

        "#{build_int(whole.to_s, whole_tokens)} #{num_str}/#{den_str}"
      end

      # Best rational approximation of +magnitude+ with a denominator not
      # exceeding +max_denominator+ (brute force; denominators are tiny).
      def best_fraction(magnitude, max_denominator)
        best_num = magnitude.round(0, :half_up)
        best_den = 1
        best_err = (magnitude - best_num).abs
        (2..max_denominator).each do |den|
          num = (magnitude * den).round(0, :half_up)
          err = (magnitude - (num / den)).abs
          next unless err < best_err

          best_num = num
          best_den = den
          best_err = err
          break if err.zero?
        end
        [best_num.to_i, best_den]
      end

      def render_date(section, value, date_system, locale_data)
        tokens = section.tokens
        serial = value.to_f.abs

        has_second = tokens.any? { |t| (t[0] == :date_part && t[1] == 's') || (t[0] == :elapsed && t[1] == 's') }
        has_minute = tokens.any? { |t| (t[0] == :date_part && t[1] == 'n') || (t[0] == :elapsed && t[1] == 'm') }
        sub = tokens.find { |t| t[0] == :subsecond }

        total = serial * 86400.0
        sub_digits = 0
        if !sub.nil?
          scale = 10**sub[1]
          scaled = (total * scale).round
          total = scaled / scale
          sub_digits = scaled % scale
        elsif has_second
          total = total.round(4).floor
        elsif has_minute
          total = (total.round(4) / 60.0).floor * 60
        else
          total = total.round(4).floor
        end
        total = total.to_i

        serial_int = serial.floor
        year = month = day = wday = nil
        if tokens.any? { |t| t[0] == :date_part && ['y', 'm', 'd'].include?(t[1]) }
          year, month, day, wday = serial_to_date(serial_int, date_system)
        end

        time_of_day = total % 86400
        hour = time_of_day / 3600
        minute = (time_of_day % 3600) / 60
        second = time_of_day % 60
        ampm = tokens.any? { |t| t[0] == :ampm }

        out = +''
        tokens.each do |t|
          case t[0]
          when :literal
            out << t[1]
          when :elapsed
            amount = case t[1]
                     when 'h' then total / 3600
                     when 'm' then total / 60
                     else total
                     end
            out << amount.to_s.rjust(t[2], '0')
          when :date_part
            out << render_date_part(t, year, month, day, wday, hour, minute, second, ampm, locale_data)
          when :ampm
            if t[1] == 'AM/PM'
              out << (hour < 12 ? locale_data['am'] : locale_data['pm'])
            else
              out << (hour < 12 ? locale_data['a'] : locale_data['p'])
            end
          when :subsecond
            out << locale_data['decimal_separator'] << sub_digits.to_s.rjust(t[1], '0')
          end
        end
        out
      end

      def render_date_part(token, year, month, day, wday, hour, minute, second, ampm, locale_data)
        letter = token[1]
        count = token[2]
        case letter
        when 'y'
          count <= 2 ? (year % 100).to_s.rjust(2, '0') : year.to_s.rjust(count, '0')
        when 'm'
          case count
          when 1 then month.to_s
          when 2 then month.to_s.rjust(2, '0')
          when 3 then locale_data['abbreviated_month_names'][month - 1]
          when 4 then locale_data['month_names'][month - 1]
          else locale_data['month_names'][month - 1][0]
        end
        when 'n'
          minute.to_s.rjust(count, '0')
        when 'd'
          case count
          when 1 then day.to_s
          when 2 then day.to_s.rjust(2, '0')
          when 3 then locale_data['abbreviated_weekday_names'][wday]
          else locale_data['weekday_names'][wday]
        end
        when 'h'
          shown = ampm ? (hour % 12).zero? ? 12 : hour % 12 : hour
          shown.to_s.rjust(count, '0')
        when 's'
          second.to_s.rjust(count, '0')
        else
          ''
        end
      end

      # Convert a day serial to [year, month, day, weekday] where weekday is
      # 0 = Sunday. See the module documentation for the 1900 leap year bug
      # compatibility rules.
      def serial_to_date(serial_int, date_system)
        if date_system == :excel_1904
          date = Date.new(1904, 1, 1) + serial_int
          return [date.year, date.month, date.day, date.wday]
        end

        wday = (serial_int + 6) % 7
        if serial_int <= 59
          date = Date.new(1899, 12, 31) + serial_int
          [date.year, date.month, date.day, wday]
        elsif serial_int == 60
          [1900, 2, 29, wday]
        else
          date = Date.new(1899, 12, 31) + serial_int - 1
          [date.year, date.month, date.day, wday]
        end
      end

      def render_general(value, locale_data, code)
        text =
          case value
          when Numeric
            if value == value.truncate && value.abs < 1e15
              value.truncate.to_i.to_s
            else
              s = value.is_a?(BigDecimal) ? value.to_s('F') : value.to_s
              if s.include?('e') || s.include?('E')
                mantissa, exponent = s.downcase.split('e')
                mantissa = mantissa.sub(/\.?0+\z/, '') if mantissa.include?('.')
                exp = exponent.to_i
                s = "#{mantissa}E#{exp.negative? ? '-' : '+'}#{exp.abs.to_s.rjust(2, '0')}"
              end
              s.sub('.', locale_data['decimal_separator'])
            end
          else
            value.to_s
          end
        Result.new(:text => text, :color => nil, :section_index => 0,
                   :type => :general, :format_code => code)
      end

      def render_text_section(section, value)
        out = +''
        section.tokens.each do |t|
          case t[0]
          when :literal then out << t[1]
          when :text_placeholder then out << value
          when :comma then out << ','
          when :slash then out << '/'
          when :decimal_point then out << '.'
          end
        end
        out
      end

      def render_literal_section(section)
        out = +''
        section.tokens.each do |t|
          out << t[1] if t[0] == :literal
        end
        out
      end
    end
  end
end
