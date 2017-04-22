require 'dentaku/calculator'
require 'dentaku/dependency_resolver'
require 'dentaku/exceptions'
require 'dentaku/parser'
require 'dentaku/tokenizer'

module Dentaku
  class BulkExpressionSolver
    def initialize(expression_hash, calculator,
    evaluate_if: nil, before_evaluation: nil, after_evaluation: nil,
    always_evaluate: false, convert_value: nil, ignore_errors: nil)
      self.expression_hash = expression_hash
      self.calculator = calculator
      self.evaluate_if = evaluate_if
      self.before_evaluation = before_evaluation
      self.after_evaluation = after_evaluation
      self.always_evaluate = always_evaluate
      self.convert_value = convert_value
      self.ignore_errors = ignore_errors
    end

    def solve!
      solve(&raise_exception_handler)
    end

    def solve(&block)
      error_handler = block || return_undefined_handler
      results = load_results(&error_handler)

      expression_hash.each_with_object({}) do |(k, _), r|
        r[k] = results[k.to_s]
      end
    end

    private

    def self.dependency_cache
      @dep_cache ||= {}
    end

    attr_accessor :expression_hash, :calculator,
      :evaluate_if, :before_evaluation, :after_evaluation, :always_evaluate,
      :convert_value, :ignore_errors

    def return_undefined_handler
      ->(*) { :undefined }
    end

    def raise_exception_handler
      ->(ex) { raise ex }
    end

    def load_results(&block)
      variables_in_resolve_order.each_with_object({}) do |var_name, r|
        begin
          value_from_memory = calculator.memory[var_name]

          if value_from_memory.nil? &&
              expressions[var_name].nil? &&
              !calculator.memory.has_key?(var_name)
            next
          end

          next if evaluate_if && !evaluate_if.call(expressions[var_name], var_name)
          before_evaluation.call(expressions[var_name], var_name) if before_evaluation

          begin
            value =
              if !value_from_memory || always_evaluate
                if value_from_memory && !(expressions.keys.include?(var_name))
                  value_from_memory
                else
                  evaluate!(expressions[var_name], expressions.merge(r))
                end
              elsif value_from_memory
                value_from_memory
              end
          rescue Exception => ex
            if ignore_errors
              next
            else
              raise ex
            end
          end

          value = convert_value.call(expressions[var_name], var_name, value) if convert_value

          after_evaluation.call(expressions[var_name], var_name, value) if after_evaluation
          r[var_name] = value
        rescue Dentaku::UnboundVariableError, ZeroDivisionError => ex
          ex.recipient_variable = var_name
          r[var_name] = block.call(ex)
        end
      end
    end

    def expressions
      @expressions ||= Hash[expression_hash.map { |k,v| [k.to_s, v] }]
    end

    def expression_dependencies
      dependencies = expressions.map do |var, expr|
        begin
          [var, calculator.dependencies(expr, ignore_memory: always_evaluate)]
        rescue Exception => ex
          if ignore_errors
            nil
          else
            raise ex
          end
        end
      end
      dependencies.compact!
      Hash[dependencies].tap do |d|
        d.values.each do |deps|
          unresolved = deps.reject { |ud| d.has_key?(ud) }
          unresolved.each { |u| add_dependencies(d, u) }
        end
      end
    end

    def add_dependencies(current_dependencies, variable)
      node = calculator.memory[variable]
      if node.respond_to?(:dependencies)
        current_dependencies[variable] = node.dependencies
        node.dependencies.each { |d| add_dependencies(current_dependencies, d) }
      end
    end

    def variables_in_resolve_order
      cache_key = expressions.keys.map(&:to_s).sort.join("|")
      @ordered_deps ||= self.class.dependency_cache.fetch(cache_key) {
        DependencyResolver.find_resolve_order(expression_dependencies).tap do |d|
          self.class.dependency_cache[cache_key] = d if Dentaku.cache_dependency_order?
        end
      }
    end

    def evaluate!(expression, results)
      calculator.evaluate!(expression, results)
    end
  end
end
