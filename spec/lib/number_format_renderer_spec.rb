require 'spec_helper'
require 'yaml'

describe RubyXL::NumberFormatRenderer do
  let(:renderer) { RubyXL::NumberFormatRenderer }

  def render(value, format, **options)
    renderer.render(value, format, **options)
  end

  describe 'offline sample file' do
    samples = YAML.load_file(File.join(__dir__, '..', 'fixtures', 'number_format_samples.yml'))['samples']

    samples.each do |sample|
      it sample['name'] do
        result = render(sample['value'], sample['format'],
                        :locale => sample['locale'] || 'en-US',
                        :date_system => (sample['date_system'] || 'excel_1900').to_sym)
        expect(result.ok?).to(eq(true), "expected ok, got failure: #{result.respond_to?(:detail) ? result.detail : nil}")
        expect(result.text).to(eq(sample['expect_text']))
        expect(result.color).to(eq(sample['expect_color'].to_sym)) if sample.key?('expect_color')
      end
    end
  end

  describe 'structured failures' do
    it 'reports in-format locale directives instead of passing the raw value through' do
      result = render(1, '[$-409]0.00')
      expect(result.ok?).to(eq(false))
      expect(result.reason).to(eq(:unsupported_locale_directive))
      expect(result.directive).to eq('[$-409]')
      expect(result.detail).to be_a(String)
    end

    it 'reports currency locale directives' do
      result = render(1, '[$EUR-407]#,##0.00')
      expect(result.ok?).to(eq(false))
      expect(result.reason).to(eq(:unsupported_locale_directive))
      expect(result.directive).to eq('[$EUR-407]')
    end

    it 'reports DBNum modifiers' do
      result = render(1, '[DBNum1]0')
      expect(result.ok?).to(eq(false))
      expect(result.reason).to(eq(:unsupported_locale_directive))
    end

    it 'reports unknown locale tags' do
      result = render(1, '0.00', :locale => 'fr-FR')
      expect(result.ok?).to(eq(false))
      expect(result.reason).to(eq(:unsupported_locale))
    end

    it 'reports invalid date systems' do
      result = render(1, 'yyyy-mm-dd', :date_system => :stardate)
      expect(result.ok?).to(eq(false))
      expect(result.reason).to(eq(:invalid_date_system))
    end

    it 'reports negative date serials' do
      result = render(-1.5, 'yyyy-mm-dd')
      expect(result.ok?).to(eq(false))
      expect(result.reason).to(eq(:negative_date_serial))
    end

    it 'reports unknown builtin format ids' do
      result = render(1, 4999)
      expect(result.ok?).to(eq(false))
      expect(result.reason).to(eq(:unknown_builtin_format_id))
    end
  end

  describe 'entry points' do
    it 'accepts a RubyXL::NumberFormat object' do
      num_fmt = RubyXL::NumberFormat.new(:num_fmt_id => 164, :format_code => '0.0%')
      expect(render(0.125, num_fmt).text).to eq('12.5%')
    end

    it 'resolves builtin format ids' do
      expect(render(0.125, 0).text).to eq('0.125')
      expect(render(44927, 14).text).to eq('1/1/2023')
    end

    it 'accepts a custom locale data hash' do
      locale = renderer::LOCALES['en-US'].merge('decimal_separator' => ',')
      expect(render(0.5, '0.0', :locale => locale).text).to eq('0,5')
    end
  end

  describe 'result metadata' do
    it 'exposes section index and type' do
      result = render(-3, '0.0;[Red]-0.0')
      expect(result.section_index).to eq(1)
      expect(result.type).to eq(:number)
      expect(result.color).to eq(:red)
    end

    it 'marks date results' do
      expect(render(44927, 'yyyy-mm-dd').type).to eq(:date)
    end

    it 'renders text values as-is when the format has no text section' do
      result = render('hello', '0.0')
      expect(result.text).to eq('hello')
      expect(result.type).to eq(:text)
    end
  end
end
