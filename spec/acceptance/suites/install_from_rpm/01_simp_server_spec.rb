require 'spec_helper_rpm'
require 'erb'
require 'pathname'

test_name 'puppetserver via rpm'

describe 'install SIMP via rpm' do

  master              = only_host_with_role(hosts, 'master')
  master_fqdn         = fact_on(master, 'fqdn')
  agents              = hosts_with_role(hosts, 'agent')
  syslog_server_fqdns = []
  domain              = fact_on(master, 'domain')

  let(:puppetserver_status_cmd) { puppetserver_status_command(master_fqdn) }
  let(:trusted_nets) { host_networks(master) }

  context 'all hosts prep' do
    it 'should set root pw and install common repos' do
      block_on(hosts, :run_in_parallel => false) do |host|
        # set the root password
        on(host, "sed -i 's/enforce_for_root//g' /etc/pam.d/*")
        on(host, "echo '#{test_password}' | passwd root --stdin")

        host.install_package('epel-release')

        # set up the SIMP repos, which **SHOULD** include the
        # necessary puppet RPMs
        set_up_simp_repos(host)
      end
    end
  end

  context 'puppet master' do
    let(:simp_conf_template) { File.read('spec/acceptance/common_files/simp_conf.yaml.erb') }

    it 'should install simp' do
      # Remove temporary facter workaround needed for beaker host prep
      uninstall_system_factor_gem(master)

      master.install_package('simp-adapter-foss')
      master.install_package('simp')
    end

    it 'should ensure FIPS mode is appropriate' do
      if ENV['BEAKER_fips'] == 'yes' and !fips_enabled(master)
        enable_fips_mode_on(master)
      end
    end

    it 'should run create answers file for simp config' do
      # The following variables/methods are required by simp_conf.yaml.erb:
      #   domain
      #   gateway
      #   interface
      #   ipaddress
      #   master_fqdn
      #   nameserver
      #   netmask
      #   syslog_server_fqdns
      #   trusted_nets
      #
      trusted_nets =  host_networks(master)
      expect(trusted_nets).to_not be_empty

      network_info = dhcp_info(master)
      expect(network_info).to_not be_nil
      gateway   = network_info[:gateway]
      interface = network_info[:interface]
      ipaddress = network_info[:ip]
      netmask   = network_info[:netmask]

      master.install_package('bind-utils') # for dig
      nameserver = dns_nameserver(master)
      expect(nameserver).to_not be_nil

      create_remote_file(master, '/root/simp_conf.yaml', ERB.new(simp_conf_template).result(binding))
      on(master, 'cat /root/simp_conf.yaml')
    end

    it 'should run simp config' do
      cmd = [
        'simp config',
        '-A /root/simp_conf.yaml'
      ].join(' ')

      input = [
        'no', # do not autogenerate GRUB password
        test_password,
        test_password,
        'no', # do not autogenerate LDAP Root password
        test_password,
        test_password,
        ''  # make sure to end with \n
      ].join("\n")

      on(master, cmd, { :pty => true, :stdin => input } )
      on(master, 'cat /root/.simp/simp_conf.yaml')
    end

    it 'should provide default hieradata to make beaker happy' do
      beaker_hiera = YAML.load(File.read('spec/acceptance/common_files/beaker_hiera.yaml'))
      hiera = beaker_hiera.merge( 'simp::rsync_stunnel' => master_fqdn )

      create_remote_file(master, '/etc/puppetlabs/code/environments/simp/data/default.yaml', hiera.to_yaml)
      on(master, 'chown root.puppet /etc/puppetlabs/code/environments/simp/data/default.yaml')
      on(master, 'chmod g+r /etc/puppetlabs/code/environments/simp/data/default.yaml')
    end

    it 'should enable autosign' do
      enable_puppet_autosign(master, domain)
    end

    it 'should run simp bootstrap' do
      # Remove the lock file because we've already added the vagrant user
      # access and won't be locked out of the VM
      on(master, 'rm -f /root/.simp/simp_bootstrap_start_lock')
      on(master, 'simp bootstrap -u --remove_ssldir', :pty => true)
    end

    it 'should reboot the master' do
      master.reboot
      retry_on(master, puppetserver_status_cmd, :retry_interval => 10)
    end

    it 'should settle after reboot' do
      on(master, '/opt/puppetlabs/bin/puppet agent -t', :acceptable_exit_codes => [0,2,4,6])
      on(master, '/opt/puppetlabs/bin/puppet agent -t', :acceptable_exit_codes => [0] )
    end

    it 'should generate agent certs' do
      generate_application_certs(master, agents, domain)
    end

    #TODO is this needed?
    it 'should mock freshclam' do
      master.install_package('clamav-update')
      ## # Uncomment to use real FreshClam data from the internet
      ## create_remote_file(master, '/tmp/freshclam.conf', <<-EOF.gsub(/^\s+/,'')
      ##     DatabaseDirectory /var/simp/environments/production/rsync/Global/clamav
      ##     DatabaseMirror database.clamav.net
      ##     Bytecode yes
      ##   EOF
      ## )
      ## on(master, 'freshclam -u root --config-file=/tmp/freshclam.conf')
      ## on(master, 'chown clam.clam /var/simp/environments/production/rsync/Global/clamav/*')
      ## on(master, 'chmod u=rw,g=rw,o=r /var/simp/environments/production/rsync/Global/clamav/*')

      # Mock ClamAV data by just `touch`ing the data files
      on(master, 'touch /var/simp/environments/production/rsync/Global/clamav/{daily,bytecode,main}.cvd')
    end
  end

  context 'puppet agents' do
    it 'should install packages and repos needed for client bootstrapping' do
      block_on(agents, :run_in_parallel => false) do |agent|
        # Remove temporary facter workaround needed for beaker host prep
        uninstall_system_factor_gem(agent)

        agent.install_package('puppet-agent')
        agent.install_package('net-tools')
      end
    end

    it 'should ensure FIPS mode is set per test' do
      block_on(agents, :run_in_parallel => false) do |agent|
        if ENV['BEAKER_fips'] == 'yes' and !fips_enabled(agent)
          enable_fips_mode_on(agent)
        end
      end
    end

    it 'set up and run puppet' do
      block_on(agents, :run_in_parallel => false) do |agent|
        on(agent, "puppet config set server #{master_fqdn}")
        on(agent, 'puppet config set masterport 8140')
        on(agent, 'puppet config set ca_port 8141')

        # Run puppet and expect changes
        retry_on(agent, '/opt/puppetlabs/bin/puppet agent -t',
          :desired_exit_codes => [0,2],
          :retry_interval     => 15,
          :max_retries        => 5,
          :verbose            => true.to_s # work around beaker bug
        )

        # Wait for machine to come back up
        agent.reboot
        retry_on(master, puppetserver_status_cmd, :retry_interval => 10)
        retry_on(agent, 'uptime', :retry_interval => 15 )

        # Wait for things to settle and stop making changes
        retry_on(agent, '/opt/puppetlabs/bin/puppet agent -t',
          :desired_exit_codes => [0],
          :retry_interval     => 15,
          :max_retries        => 3,
          :verbose            => true.to_s # work around beaker bug
        )
      end
    end
  end
end
