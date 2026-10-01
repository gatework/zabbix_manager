# frozen_string_literal: true

class ZabbixManager
  class Monitoring
    # 通过原生 API 编排设备；调用方保存 managed 回执，本对象不持久化任何状态。
    class Device
      ROUTING_FIELDS = %i[monitored_by proxyid proxy_hostid proxy_groupid].freeze
      RECEIPT_FIELDS = %i[group_ids template_ids tag_names].freeze

      # @param attributes [Hash] 原生主机字段及 enabled、proxy、proxy_group、snmp、managed
      # @option attributes [Array<String, Hash>] groups 群组名称或包含 groupid 的 Hash
      # @option attributes [Array<String, Hash>] templates 模板技术名或包含 templateid 的 Hash
      # @option attributes [Hash] snmp v1/v2c 的 ip 或 dns、community 及可选 port、macro、interfaceid
      # @option attributes [Hash] managed 上次回执中的 group_ids、template_ids、tag_names。
      #   显式期望的成员进入本次管理范围；同名但值不同的未管理标签会拒绝覆盖。
      # @raise [Invalid] 输入不完整、冲突或类型错误；此阶段不访问远端
      def initialize(attributes)
        @attributes = Validation.hash!(attributes, "device").deep_dup
        Validation.text!(@attributes[:host], "device.host")
        unless Validation::HOST_NAME.match?(@attributes[:host])
          raise Invalid, "device.host contains unsupported characters"
        end

        Validation.text!(@attributes[:name], "device.name") if @attributes.key?(:name)
        enum!(@attributes[:inventory_mode], [-1, 0, 1], "inventory_mode") if @attributes.key?(:inventory_mode)
        validate_status!
        @managed = normalize_managed(@attributes.key?(:managed) ? @attributes.delete(:managed) : {})
        validate_collections!
        validate_routing!
        prepare_snmp!
        validate_interfaces!
        validate_macros!
      end

      # @return [String] 设备的稳定技术主机名
      def identity
        @attributes.fetch(:host).dup
      end

      # @return [Hash] 可安全放入批量结果的设备身份，不含接口和宏凭据
      def safe_identity
        @attributes.slice(:host, :name).compact.deep_dup
      end

      # @return [String] 不包含凭据的调试标识
      def inspect
        "#<#{self.class} #{safe_identity.inspect}>"
      end

      # 先完成名称解析、版本与接口归属校验，再执行写入。多次 API 写入不是远端事务。
      # 失败的写入不重试、不回滚；调用方应保留异常并重新读取远端状态。
      # @param manager [ZabbixManager] 已认证的共享连接
      # @return [Hash] hostid、enabled 及 managed（包含 group_ids、template_ids 和 tag_names）
      #   停用且主机不存在时 hostid 为 nil，且不执行创建。
      def reconcile(manager)
        existing = find_existing(manager)
        unless @enabled
          manager.hosts.set_status([existing.fetch("hostid")], enabled: false) if existing
          return receipt(existing&.fetch("hostid"), @managed)
        end

        validate_version!(manager.client.api_version)
        attributes, managed = resolve_attributes(manager, existing)
        unless existing
          validate_creation!(manager, attributes)
          # 仅协调创建；不嵌套接口锁，也不承诺跨进程或远端事务隔离。
          outcome, value = manager.client.with_upsert_lock("host-create:#{identity}") do
            current = find_existing(manager)
            current ? [:existing, current] : [:created, manager.hosts.create(attributes)]
          end
          return receipt(value, managed) if outcome == :created

          existing = value
          attributes, managed = resolve_attributes(manager, existing)
        end
        update_existing(manager, existing, attributes)
        receipt(existing.fetch("hostid"), managed)
      end

      private

      def validate_status!
        supplied = @attributes.key?(:enabled)
        enabled = @attributes.delete(:enabled)
        if supplied && enabled != true && enabled != false
          raise Invalid, "device.enabled must be true or false"
        end

        if @attributes.key?(:status)
          status = enum!(@attributes[:status], [0, 1], "device.status")
          unless enabled.nil? || enabled == status.zero?
            raise Invalid, "device.enabled and status disagree"
          end

          enabled = status.zero?
        end
        @enabled = enabled.nil? ? true : enabled
        @attributes[:status] = @enabled ? 0 : 1
      end

      def normalize_managed(value)
        managed = Validation.hash!(value, "managed")
        raise Invalid, "unknown managed field" if (managed.keys - RECEIPT_FIELDS).any?

        RECEIPT_FIELDS.to_h do |field|
          values = Validation.array!(managed.fetch(field, []), "managed.#{field}").map do |item|
            field == :tag_names ? Validation.text!(item, "managed.tag_names") :
              Validation.positive_id!(item, "managed.#{field}").to_s
          end
          [field, values.uniq]
        end
      end

      def validate_collections!
        { groups: :groupid, templates: :templateid }.each do |field, id|
          next unless @attributes.key?(field)

          @attributes[field] = Validation.array!(@attributes[field], field).map do |reference|
            if reference.is_a?(String)
              Validation.text!(reference, field)
            else
              value = Validation.hash!(reference, field)
              raise Invalid, "#{field} references require only #{id}" unless value.keys == [id]

              { id => Validation.positive_id!(value[id], id).to_s }
            end
          end
        end
        if @attributes.key?(:inventory)
          inventory = Validation.hash!(@attributes[:inventory], "inventory")
          raise Invalid, "inventory values must be strings" unless inventory.values.all? { |value| value.is_a?(String) }
        end
        return unless @attributes.key?(:tags)

        @attributes[:tags] = Validation.array!(@attributes[:tags], "tags").map do |tag|
          value = Validation.hash!(tag, "tag")
          raise Invalid, "tags accept only tag and value" if (value.keys - %i[tag value]).any?

          Validation.text!(value[:tag], "tag.tag")
          raise Invalid, "tag.value must be a string" unless value.fetch(:value, "").is_a?(String)

          { tag: value[:tag], value: value.fetch(:value, "") }
        end
      end

      def validate_routing!
        convenience = @attributes.keys & %i[proxy proxy_group]
        if convenience.length > 1 || (convenience.any? && (@attributes.keys & ROUTING_FIELDS).any?)
          raise Invalid, "choose one proxy routing reference"
        end

        convenience.each do |field|
          value = @attributes[field]
          next Validation.text!(value, field) if value.is_a?(String)

          id = field == :proxy ? :proxyid : :proxy_groupid
          reference = Validation.hash!(value, field)
          raise Invalid, "#{field} requires only #{id}" unless reference.keys == [id]

          Validation.positive_id!(reference[id], id)
          @attributes[field] = reference
        end
        (%i[proxyid proxy_hostid proxy_groupid] & @attributes.keys).each do |id|
          Validation.positive_id!(@attributes[id], id)
        end
        return unless @attributes.key?(:monitored_by)

        mode = enum!(@attributes[:monitored_by], [0, 1, 2], "monitored_by")
        required = { 1 => :proxyid, 2 => :proxy_groupid }[mode]
        Validation.positive_id!(@attributes[required], required) if required
      end

      def prepare_snmp!
        return unless @attributes.key?(:snmp)
        raise Invalid, "snmp and interfaces cannot be combined" if @attributes.key?(:interfaces)

        snmp = Validation.hash!(@attributes.delete(:snmp), "snmp")
        allowed = %i[ip dns community macro port version bulk interfaceid]
        raise Invalid, "unknown snmp field" if (snmp.keys - allowed).any?
        raise Invalid, "snmp requires exactly one of ip or dns" unless (snmp.keys & %i[ip dns]).one?

        endpoint = snmp.key?(:ip) ? :ip : :dns
        Validation.text!(snmp[endpoint], "snmp.#{endpoint}")
        Validation.text!(snmp[:community], "snmp.community")
        macro = snmp.fetch(:macro, "{$SNMP_COMMUNITY}")
        @snmp = {
          type: 2, main: 1, useip: endpoint == :ip ? 1 : 0,
          ip: snmp.fetch(:ip, ""), dns: snmp.fetch(:dns, ""), port: snmp.fetch(:port, "161").to_s,
          details: { version: enum!(snmp.fetch(:version, 2), [1, 2], "snmp.version"),
                     bulk: enum!(snmp.fetch(:bulk, 1), [0, 1], "snmp.bulk"), community: macro }
        }
        if snmp.key?(:interfaceid)
          @snmp[:interfaceid] = Validation.positive_id!(snmp[:interfaceid], "snmp.interfaceid")
        end
        @attributes[:interfaces] = [@snmp]
        macros = Validation.array!(@attributes.fetch(:macros, []), "macros")
        @attributes[:macros] = macros + [{ macro: macro, value: snmp[:community], type: 1 }]
      end

      def validate_interfaces!
        return unless @attributes.key?(:interfaces)

        interfaces = Validation.array!(@attributes[:interfaces], "interfaces").map do |interface|
          value = Validation.hash!(interface, "interface")
          Validation.positive_id!(value[:interfaceid], "interfaceid") if value.key?(:interfaceid)
          value
        end
        @attributes[:interfaces] = HostInterfaces.new(nil).validate(interfaces)
      end

      def validate_macros!
        return unless @attributes.key?(:macros)

        @attributes[:macros] = Validation.array!(@attributes[:macros], "macros").map do |macro|
          value = Validation.hash!(macro, "macro")
          raise Invalid, "macros accept macro, value, type and description" if
            (value.keys - %i[macro value type description]).any?
          unless value[:macro].is_a?(String) && value[:macro].match?(/\A\{\$[^{}\r\n]+\}\z/)
            raise Invalid, "macro name must use {$NAME} syntax"
          end
          raise Invalid, "macro value must be a string" unless value[:value].is_a?(String)

          enum!(value.fetch(:type, 0), [0, 1, 2], "macro.type")
          value
        end
        names = @attributes[:macros].pluck(:macro)
        raise Invalid, "duplicate macro name" unless names.uniq == names
      end

      def enum!(value, allowed, name)
        unless (value.is_a?(String) || value.is_a?(Integer)) && allowed.map(&:to_s).include?(value.to_s)
          raise Invalid, "#{name} must be one of #{allowed.join(', ')}"
        end

        value.to_i
      end

      def validate_version!(version)
        version = Gem::Version.new(version)
        modern = version >= Gem::Version.new("7.0")
        unsupported = modern ? [:proxy_hostid] : %i[proxy_group proxy_groupid proxyid monitored_by]
        raise Invalid, "proxy routing is unsupported by this Zabbix version" if (@attributes.keys & unsupported).any?

        if modern && (@attributes.keys & %i[proxyid proxy_groupid]).any?
          mode = @attributes[:monitored_by].to_s
          expected = { "1" => :proxyid, "2" => :proxy_groupid }[mode]
          actual = @attributes.keys & %i[proxyid proxy_groupid]
          raise Invalid, "proxy ID must match monitored_by" unless actual == [expected]
        end
        Array(@attributes[:macros]).each do |macro|
          minimum = { 1 => "5.0", 2 => "5.2" }[macro.fetch(:type, 0).to_i]
          if minimum && version < Gem::Version.new(minimum)
            raise Invalid, "macro type requires Zabbix #{minimum} or newer"
          end
        end
      end

      def find_existing(manager)
        modern = Gem::Version.new(manager.client.api_version) >= Gem::Version.new("7.0")
        group_field = modern ? :selectHostGroups : :selectGroups
        hosts = manager.hosts.get_raw(
          filter: { host: identity }, output: %w[hostid host], group_field => ["groupid"],
          selectParentTemplates: ["templateid"], selectTags: "extend", selectInterfaces: "extend"
        )
        unless hosts.is_a?(Array) && hosts.all? { |host| host.is_a?(Hash) && host["host"] == identity }
          raise ProtocolError, "invalid device lookup response"
        end
        raise Conflict, "multiple hosts match device identity" if hosts.length > 1

        hosts.first&.tap do |host|
          remote_id!(host["hostid"], "hostid")
          host["groups"] = host.fetch("hostgroups") if modern && host.key?("hostgroups")
          %w[groups parentTemplates tags interfaces].each do |field|
            unless host[field].is_a?(Array) && host[field].all? { |entry| entry.is_a?(Hash) }
              raise ProtocolError, "device response is missing #{field}"
            end
          end
        end
      end

      def resolve_attributes(manager, existing)
        attributes = @attributes.except(:proxy, :proxy_group).deep_dup
        managed = @managed.deep_dup
        { groups: [:host_groups, :groupid, :name, :group_ids, "groups"],
          templates: [:templates, :templateid, :host, :template_ids, "parentTemplates"] }.each do |field, mapping|
          next unless attributes.key?(field)

          resource, id_key, name_key, receipt_key, remote_key = mapping
          ids = attributes[field].map do |reference|
            reference.is_a?(Hash) ? reference.fetch(id_key).to_s :
              resolve_name(manager.public_send(resource), name_key, reference).to_s
          end.uniq
          current = existing ? existing.fetch(remote_key).map { |item| remote_id!(item[id_key.to_s], id_key) } : []
          attributes[field] = ((current - @managed[receipt_key]) | ids).map { |id| { id_key => id } }
          managed[receipt_key] = ids
        end
        if attributes.key?(:tags)
          tags = existing ? existing.fetch("tags").map { |tag| remote_tag!(tag) } : []
          desired = attributes[:tags]
          unowned = tags.reject { |tag| @managed[:tag_names].include?(tag[:tag]) }
          names = desired.pluck(:tag)
          if unowned.any? { |tag| names.include?(tag[:tag]) && !desired.include?(tag) }
            raise Conflict, "desired tag name has an unmanaged value"
          end

          attributes[:tags] = unowned + desired
          attributes[:tags].uniq!
          managed[:tag_names] = @attributes[:tags].pluck(:tag).uniq
        end
        resolve_routing(manager, attributes)
        if @snmp && existing && !@snmp.key?(:interfaceid)
          main = existing.fetch("interfaces").select { |item| item["type"].to_s == "2" && item["main"].to_s == "1" }
          raise Conflict, "multiple main SNMP interfaces; provide interfaceid" if main.length > 1

          attributes[:interfaces].first[:interfaceid] =
            remote_id!(main.first["interfaceid"], "interfaceid") if main.one?
        end
        raise Invalid, "groups cannot be empty" if attributes.key?(:groups) && attributes[:groups].empty?

        [attributes, managed]
      end

      def resolve_name(resource, field, name)
        resource.get_id(field => name) || raise(ApiError, "required #{resource.method_name} was not found")
      end

      def resolve_routing(manager, attributes)
        %i[proxy proxy_group].each do |field|
          next unless @attributes.key?(field)

          reference = @attributes[field]
          resource = field == :proxy ? manager.proxies : manager.proxy_groups
          id_key = field == :proxy ? :proxyid : :proxy_groupid
          id = if reference.is_a?(Hash)
                 reference.fetch(id_key)
               else
                 resolve_name(resource, resource.identify.to_sym, reference)
               end
          if Gem::Version.new(manager.client.api_version) < Gem::Version.new("7.0")
            attributes[:proxy_hostid] = id
          else
            attributes[:monitored_by] = field == :proxy ? 1 : 2
            attributes[id_key] = id
          end
        end
      end

      def validate_creation!(manager, attributes)
        raise Invalid, "groups are required when creating a device" if attributes.fetch(:groups, []).empty?
        raise Invalid, "interfaces are required when creating a device" if attributes.fetch(:interfaces, []).empty?
        if attributes[:interfaces].any? { |interface| interface.key?(:interfaceid) }
          raise Invalid, "new devices cannot reference existing interface IDs"
        end

        manager.host_interfaces.validate_for_create(attributes[:interfaces])
      end

      def update_existing(manager, existing, attributes)
        hostid = existing.fetch("hostid")
        interfaces = attributes.delete(:interfaces)
        macros = attributes.delete(:macros) || []
        manager.host_interfaces.validate_for_host(hostid: hostid, interfaces: interfaces) if interfaces&.any?
        macro_plan = macros.map do |macro|
          [macro, manager.user_macros.get_id(hostid: hostid, macro: macro.fetch(:macro))]
        end
        macro_plan.each do |macro, id|
          id ? manager.user_macros.update(macro.merge(hostmacroid: id)) :
            manager.user_macros.create(macro.merge(hostid: hostid))
        end
        manager.host_interfaces.reconcile_for_host(hostid: hostid, interfaces: interfaces) if interfaces&.any?
        manager.hosts.update(attributes.merge(hostid: hostid))
      end

      def remote_id!(value, field)
        Validation.positive_id!(value, field).to_s
      rescue Invalid
        raise ProtocolError, "invalid device response #{field}", cause: nil
      end

      def remote_tag!(tag)
        unless tag["tag"].is_a?(String) && tag["value"].is_a?(String)
          raise ProtocolError, "invalid device tag response"
        end

        { tag: tag["tag"], value: tag["value"] }
      end

      def receipt(hostid, managed)
        { hostid: hostid&.to_i, enabled: @enabled, managed: managed.deep_dup }
      end
    end
  end
end
