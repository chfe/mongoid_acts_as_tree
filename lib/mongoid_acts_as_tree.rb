require 'mongoid'

module Mongoid
  module Acts
    module Tree
      def self.included(model)
        model.class_eval do
          extend InitializerMethods
        end
      end

      module InitializerMethods
        def acts_as_tree(options = {})
          options = {
            parent_id_field: 'parent_id',   # the field holding the parent_id
            path_field: 'path', # the field holding the path (Array of ObjectIds)
            depth_field: 'depth', # the field holding the depth (Integer)
            base_class: self, # the base class if STI is used
            autosave: true # persist on change?
          }.merge(options)

          # set order to depth_field as default
          options[:order] = [options[:depth_field], :asc] unless options[:order].present?

          # setting scope if present
          if options[:scope].is_a?(Symbol) && options[:scope].to_s !~ /_id$/
            options[:scope] = "#{options[:scope]}_id".intern
          end

          # constantize base class if passed as string
          options[:base_class] = options[:base_class].constantize! if options[:base_class].is_a?(String)

          # write_inheritable_attribute :acts_as_tree_options, options
          class_attribute :acts_as_tree_options
          self.acts_as_tree_options = options
          class_inheritable_reader :acts_as_tree_options

          extend Fields
          extend ClassMethods

          # build a relation
          belongs_to  :parent, class_name: tree_base_class.to_s, foreign_key: parent_id_field,
                               polymorphic: true

          # build relation to children
          has_many    :children,
                      class_name: tree_base_class.to_s,
                      foreign_key: parent_id_field,
                      order: options[:order]

          include InstanceMethods
          include Fields

          field path_field, type: Array, default: [], index: true # holds the path
          field depth_field, type: Integer, default: 0 # holds the depth

          # make sure child and parent are in the same scope
          validate        :validate_scope, if: :will_move?
          # detect any cyclic tree structures
          validate        :validate_cyclic, if: :will_move?

          # handle movement
          around_save     :handle_move, if: :will_move?

          # destroy descendants
          before_destroy  :destroy_descendants

          # a nice callback
          define_callbacks :move, terminator: 'result==false'
        end
      end

      module ClassMethods
        # get all root nodes
        def roots
          where(parent_id_field => nil)
        end
      end

      module InstanceMethods
        def root?
          parent_id.nil?
        end

        def child?
          !root?
        end

        def root
          root? ? self : tree_scope.find({ :_id.in => path, :parent_id => nil })
        end

        def ancestors
          tree_scope.where(:_id.in => path)
        end

        def self_and_ancestors
          tree_scope.where(:_id.in => [_id] + path)
        end

        def siblings
          tree_scope.where(:_id.ne => id, parent_id_field => parent_id)
        end

        def self_and_siblings
          tree_scope.where(parent_id_field => parent_id)
        end

        def descendants
          tree_scope.all_in(path_field => [id])
        end

        def self_and_descendants
          # new query to ensure tree order
          tree_scope.where({
                             '$or' => [
                               { path_field => { '$all' => [id] } },
                               { _id: id }
                             ]
                           })
        end

        def is_ancestor_of?(other)
          other.path.include?(id) && same_scope?(other)
        end

        def is_or_is_ancestor_of?(other)
          ((other == self) || is_ancestor_of?(other)) && same_scope?(other)
        end

        def is_descendant_of?(other)
          path.include?(other.id) && same_scope?(other)
        end

        def is_or_is_descendant_of?(other)
          ((other == self) || is_descendant_of?(other)) && same_scope?(other)
        end

        def is_sibling_of?(other)
          (other != self) && (other.parent_id == parent_id) && same_scope?(other)
        end

        def is_or_is_sibling_of?(other)
          ((other == self) || is_sibling_of?(other)) && same_scope?(other)
        end

        def destroy_descendants
          descendants.each(&:destroy)
        end

        def same_scope?(other)
          scope_field_names.all? do |attr|
            self[attr] == other[attr]
          end
        end

        # setter and getters

        def depth
          read_attribute depth_field
        end

        def path
          read_attribute path_field
        end

        # !!!! DO NOT SET DEPTH MANUALY !!!!
        def depth=(new_depth)
          write_attribute depth_field, new_depth
        end

        # !!!! DO NOT SET PATH MANUALLY !!!!
        def path=(new_path)
          write_attribute path_field, new_path
        end

        def parent_id
          read_attribute parent_id_field
        end

        # detect movement
        # moves if: new record, parent_id has changed
        def will_move?
          !persisted? || send("#{parent_id_field}_changed?")
        end

        protected

        def validate_scope
          # if parent exists, make sure child and parent are in the same scope
          return unless !root? && !same_scope?(parent)

          errors.add(:parent_id, 'not in the same scope')
        end

        def validate_cyclic
          cyclic = persisted? && self_and_descendants.where(_id: parent_id).count > 0
          cyclic ||= (parent.present? && parent == self)

          errors.add(:parent_id, 'Cyclic Tree Structure') if cyclic
        end

        def handle_move
          old_segments  = path
          delta_depth   = depth
          was_persisted = persisted?

          run_callbacks :move do
            if !parent_id.nil? && parent.present?
              self.path   = parent.path + [parent.id]
              self.depth  = parent.depth + 1
            else
              self.path   = []
              self.depth  = 0
            end

            yield

            # if the node was persisted before it may have children we need to update
            if was_persisted
              # delta_depth = current depth - previous depth
              delta_depth         = depth - delta_depth
              # get the difference of path segments
              segments_to_delete  = old_segments - path
              # get the difference of path segments the other way around
              segments_to_insert  = path - old_segments

              # 1. pull old elements from path,
              tree_base_class.collection.update({ path_field => { '$all' => [id] } },
                                                { '$pullAll' => { "#{path_field}" => segments_to_delete }, '$inc' => { "#{depth_field}" => delta_depth } }, multi: true)
              # 2. update set all new elements, if any
              unless segments_to_insert.empty?
                tree_base_class.collection.update({ path_field => { '$all' => [id] } },
                                                  { '$addToSet' => { "#{path_field}" => segments_to_insert } }, multi: true)
              end
            end
          end
        end

        def tree_scope(options = {})
          tree_base_class.scoped.tap do |new_scope|
            new_scope.selector.merge!(scope_field_names.inject({}) do |conditions, attr|
                                        conditions.merge attr => self[attr]
                                      end)
            new_scope.options.merge!({ sort: tree_order }.merge(options))
          end
        end
      end

      module Fields
        def parent_id_field
          acts_as_tree_options[:parent_id_field]
        end

        def path_field
          acts_as_tree_options[:path_field]
        end

        def depth_field
          acts_as_tree_options[:depth_field]
        end

        def tree_order
          acts_as_tree_options[:order] or []
        end

        def scope_field_names
          Array.wrap(acts_as_tree_options[:scope])
        end

        def tree_autosave
          acts_as_tree_options[:autosave]
        end

        def tree_base_class
          acts_as_tree_options[:base_class]
        end
      end
    end
  end
end
