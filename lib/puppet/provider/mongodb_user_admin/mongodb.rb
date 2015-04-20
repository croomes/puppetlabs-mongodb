require File.expand_path(File.join(File.dirname(__FILE__), '..', 'mongodb'))
Puppet::Type.type(:mongodb_user_admin).provide(:mongodb, :parent => Puppet::Provider::Mongodb) do

  desc "Manage user administrator for a MongoDB server."

  defaultfor :kernel => 'Linux'

  def self.instances
    if mongo_24?
      users = mongo_command('db.system.users.find().toArray()', {'retries' => 5})

      allusers += users.collect do |user|
          new(:name          => user['_id'],
              :ensure        => :present,
              :username      => user['user'],
              :roles         => user['roles'].sort,
              :password_hash => user['pwd'])
      end
      return allusers
    else
      users = mongo_command('db.system.users.find().toArray()', {'retries' => 5})

      users.collect do |user|
          new(:name          => user['_id'],
              :ensure        => :present,
              :username      => user['user'],
              :roles         => from_roles(user['roles'], 'admin'),
              :password_hash => user['credentials']['MONGODB-CR'])
      end
    end
  end

  # Assign prefetched users based on username, not on id and name
  def self.prefetch(resources)
    users = instances
    resources.each do |name, resource|
      if provider = users.find { |user| user.username == resource[:username] }
        resources[name].provider = provider
      end
    end
  end

  mk_resource_methods

  def create

    if mongo_24?
      user = {
        :user => @resource[:username],
        :pwd => @resource[:password],
        :roles => @resource[:roles]
      }

      mongo_command("db.addUser(#{user.to_json})")
    else
      user = {
        :user => @resource[:username],
        :pwd => @resource[:password],
        :customData => { :createdBy => "Puppet Mongodb_user_admin[#{@resource[:name]}]" },
        :roles => @resource[:roles].map! { |role| {"role" => role, "db" => "admin"}}
      }

      mongo_command("db.createUser(#{user.to_json})", {'json' => false})
    end

    @property_hash[:ensure] = :present
    @property_hash[:username] = @resource[:username]
    @property_hash[:password] = @resource[:password]
    @property_hash[:password_hash] = ''
    @property_hash[:roles] = @resource[:roles]

    exists? ? (return true) : (return false)
  end


  def destroy
    if mongo_24?
      mongo_command("db.removeUser('#{@resource[:username]}')")
    else
      mongo_command("db.dropUser('#{@resource[:username]}')")
    end
  end

  def exists?
    !(@property_hash[:ensure] == :absent or @property_hash[:ensure].nil?)
  end

  def password_hash=(value)
    cmd = {
        :updateUser => @resource[:username],
        :pwd => @resource[:password],
        :digestPassword => false
    }

    mongo_command("db.runCommand(#{cmd.to_json})")
  end

  def roles=(roles)
    if mongo_24?
      mongo_command("db.system.users.update({user:'#{@resource[:username]}'}, { $set: {roles: #{@resource[:roles].to_json}}})")
    else
      grant = roles-@resource[:roles]
      if grant.length > 0
        mongo_command("db.getSiblingDB('admin').grantRolesToUser('#{@resource[:username]}', #{grant.to_json})")
      end

      revoke = @resource[:roles]-roles
      if revoke.length > 0
        mongo_command("db.getSiblingDB('admin').revokeRolesFromUser('#{@resource[:username]}', #{revoke.to_json})")
      end
    end
  end

  private

  def self.from_roles(roles, db)
    roles.map do |entry|
      if entry['db'] == db
        entry['role']
      else
        "#{entry['role']}@#{entry['db']}"
      end
    end.sort
  end

end
