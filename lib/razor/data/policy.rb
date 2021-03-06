module Razor::Data
  class Policy < Sequel::Model

    one_to_many  :nodes
    many_to_one  :repo
    many_to_many :tags
    many_to_one  :broker

    plugin :list, :field => :rule_number
    plugin :serialization, :json, :node_metadata

    def before_validation
      # @todo lutter 2014-01-15: the list plugin initializes +rule_number+
      # too late (in a before_create hook) at which point the not null
      # validation for rule_number has already failed
      self.rule_number ||= Policy.dataset.max(:rule_number).to_i + 1
      super
    end

    # Put this policy into a different place in the policy table; +where+
    # can be either +before+ or +after+, +other+ must be a policy.
    def move(where, other)
      raise "Save object first. List plugin can not move unsaved objects" if new?
      if where.to_sym == :before
        move_to(other.position_value)
      elsif where.to_sym == :after
        lp = last_position
        if other.position_value == lp
          move_to(lp, lp)
        else
          move_to(other.position_value+1, lp)
        end
      else
        raise "the where parameter must be either 'before' or 'after'"
      end
    end

    # This is a hack around the fact that the auto_validates plugin does
    # not play nice with the JSON serialization plugin (the serializaton
    # happens in the before_save hook, which runs after validation)
    #
    # To avoid spurious error messages, we tell the validation machinery to
    # expect a Hash resp.
    #
    # Add the fields to be serialized to the 'serialized_fields' array
    #
    # FIXME: Figure out a way to address this issue upstream
    def schema_type_class(k)
      if [ :node_metadata ].include?(k)
        Hash
      else
        super
      end
    end

    def task
      Razor::Task.find(task_name)
    end

    def validate
      super

      # Because we allow tasks in the file system, we do not have a fk
      # constraint on +task_name+; this check only helps spot simple
      # typos etc.
      begin
        self.task
      rescue Razor::TaskNotFoundError
        errors.add(:task_name,
                   "task '#{task_name}' does not exist")
      end
    end

    def self.bind(node)
      node_tags = node.tags
      # The policies that could be bound must
      # - be enabled
      # - have at least one tag
      # - the tags must be a subset of the node's tags
      # - allow unlimited nodes (max_count is NULL) or have fewer
      #   than max_count nodes bound to them
      tag_ids = node.tags.map { |t| t.id }.join(",")
      sql = <<SQL
enabled is true
and
exists (select count(*) from policies_tags pt where pt.policy_id = policies.id)
and
(select array(select pt.tag_id from policies_tags pt where pt.policy_id = policies.id)) <@ array[#{tag_ids}]::integer[]
and
(max_count is NULL or (select count(*) from nodes n where n.policy_id = policies.id) < max_count)
SQL
      begin
        match = Policy.where(sql).order(:rule_number).first
        if match
          match.lock!
          # Make sure nobody raced us to binding to the policy
          if match.max_count.nil? or match.nodes.count < match.max_count
            node.bind(match)
            node.log_append(:event => :bind, :policy => match.name)
            node.save_changes
            break
          end
        end
      end while match && node.policy != match
    end
  end
end
