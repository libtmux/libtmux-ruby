# frozen_string_literal: true

require_relative "errors"

module LibTmux
  # Replayable captured membership. Snapshot construction owns record values.
  class Selection
    include Enumerable
    OMITTED = Object.new.freeze
    private_constant :OMITTED

    def initialize(records, entity: nil, graph: nil)
      @records = records.to_a.dup.freeze
      @entity = entity
      @graph = graph
      freeze
    end

    def each
      return enum_for(:each) { @records.length } unless block_given?

      @records.each { |record| yield record }
      self
    end

    def select
      return enum_for(:select) { @records.length } unless block_given?

      derive(@records.select { |record| yield record })
    end
    alias filter select
    alias find_all select

    def reject
      return enum_for(:reject) { @records.length } unless block_given?

      derive(@records.reject { |record| yield record })
    end

    def to_a
      @records.dup
    end

    def size
      @records.length
    end
    alias length size

    def empty?
      @records.empty?
    end

    def where(criteria = OMITTED, **keywords, &block)
      require_relative "criteria"
      raise ArgumentError, "where does not accept a block" if block
      raise InvalidFilterError.new(expected: "selection with an entity schema") unless @entity
      unless criteria.equal?(OMITTED) || keywords.empty?
        raise ArgumentError, "use positional or keyword criteria, not both"
      end
      criteria = keywords if criteria.equal?(OMITTED)
      expression = FilterExpr.build(@entity, criteria)
      derive(expression.__send__(:select_records, @records))
    end

    def one(criteria = OMITTED, **keywords, &block)
      selection = retrieval_selection(criteria, keywords, block)
      raise NoMatchError, "selection has no matches" if selection.empty?
      raise MultipleMatchesError, "selection has at least two matches" if selection.size > 1

      selection.first
    end

    def one_or_nil(criteria = OMITTED, **keywords, &block)
      selection = retrieval_selection(criteria, keywords, block)
      selection.empty? ? nil : selection.one
    end

    def exists?(criteria = OMITTED, **keywords, &block)
      !retrieval_selection(criteria, keywords, block).empty?
    end

    private

    def derive(records)
      self.class.new(records, entity: @entity, graph: @graph)
    end

    def retrieval_selection(criteria, keywords, block)
      raise ArgumentError, "retrieval methods do not accept a block" if block
      return keywords.empty? ? self : where(**keywords) if criteria.equal?(OMITTED)

      where(criteria, **keywords)
    end
  end
end
