require 'spec_helper'
require_relative '../../../lib/docker-swarm'
require 'retry_block'


#DOCKER_VERSION=1.12 
#SWARM_MASTER_ADDRESS=http://core-01:2375 
#SWARM_WORKER_ADDRESS=http://core-02:2375 RAILS_ENV=test rspec ./spec/docker/swarm/node_spec.rb

describe Docker::Swarm::Swarm do
  
  DEFAULT_SERVICE_SETTINGS = {
      "Name" => "nginx",
      "TaskTemplate" => {
        "ContainerSpec" => {
          "Networks" => [],
          "Image" => "nginx:1.11.7",
          "Mounts" => [
          ],
        },
        "Env" => ["TEST_ENV=test"],
        "LogDriver" => {
          "Name" => "json-file",
          "Options" => {
            "max-file" => "3",
            "max-size" => "10M"
          }
        },
         "Placement" => {},
         "Resources" => {
           "Limits" => {
             "MemoryBytes" => 104857600
           },
           "Reservations" => {
           }
         },
        "RestartPolicy" => {
          "Condition" => "on-failure",
          "Delay" => 1,
          "MaxAttempts" => 3
        }
      },
      "Mode" => {
        "Replicated" => {
          "Replicas" => 3
        }
      },
      "UpdateConfig" => {
        "Delay" => 2,
        "Parallelism" => 1,
        "FailureAction" => "pause"
      },
      "EndpointSpec" => {
        "Ports" => [
          {
            "Protocol" => "tcp",
            "PublishedPort" => 8181,
            "TargetPort" => 80
          }
        ]
      },
      "Labels" => {
      }
    }
    


  it "Can attach to a running swarm" do
    # CREATE A SWARM
    master_connection = Docker::Swarm::Connection.new(ENV['SWARM_MASTER_ADDRESS'])
    worker_connection = Docker::Swarm::Connection.new(ENV['SWARM_WORKER_ADDRESS'])
    
    puts "Clean up old swarm configs if they exist ..."
    Docker::Swarm::Swarm.leave(true, worker_connection)
    Docker::Swarm::Swarm.leave(true, master_connection)
    
    swarm = init_test_swarm(master_connection, ENV['SWARM_MASTER_ADDRESS'].split("//").last.split(":").first)
    worker_node = swarm.join_worker(worker_connection)
    expect(worker_node.hash).to_not be nil
    
    puts "Config and create a test swarm ..."
    service_create_options = DEFAULT_SERVICE_SETTINGS
    service_create_options['TaskTemplate']['Env'] << "TEST_ENV=test"
    service_create_options["Mode"]["Replicated"]["Replicas"] = 20
    service_create_options["EndpointSpec"]["Ports"] = [{"Protocol" => "tcp", "PublishedPort" => 8181, "TargetPort" => 80}]
    service = swarm.create_service(service_create_options)
    expect(swarm.services.length).to eq 1
    # ATTACH TO EXISTING SWARM
    swarm = Docker::Swarm::Swarm.find(master_connection, {discover_nodes: true, docker_api_port: 2375})
    expect(swarm).to_not be nil
    expect(swarm.services.length).to eq 1
    expect(swarm.nodes.length).to eq 2
  end
  
  
  it "Can remove working node gracefully" do
    master_connection = Docker::Swarm::Connection.new(ENV['SWARM_MASTER_ADDRESS'])
    worker_connection = Docker::Swarm::Connection.new(ENV['SWARM_WORKER_ADDRESS'])
    
#    swarm = Docker::Swarm::Swarm.find(master_connection)
    puts "Clean up old swarm configs if they exist ..."
    Docker::Swarm::Swarm.leave(true, worker_connection)
    begin
      Docker::Swarm::Swarm.leave(true, master_connection)
    rescue Exception => e
    end
    swarm = init_test_swarm(master_connection)
    master_node = swarm.manager_nodes.first
    worker_node = swarm.join_worker(worker_connection)
    expect(worker_node.hash).to_not be nil

    network_name = "test_network"
    master_node.remove_network_with_name(network_name)
    worker_node.remove_network_with_name(network_name)
      
    network = swarm.create_network_overlay(network_name)

    puts "Config and create a test swarm ..."
    service_create_options = DEFAULT_SERVICE_SETTINGS
    service_create_options['TaskTemplate']['Env'] << "TEST_ENV=test"
    service_create_options["Mode"]["Replicated"]["Replicas"] = 20
    service_create_options["EndpointSpec"]["Ports"] = [{"Protocol" => "tcp", "PublishedPort" => 8181, "TargetPort" => 80}]
    service_create_options['Networks'] = [ {'Target' => network.id} ]
    
    service = swarm.create_service(service_create_options)
    expect(swarm.services.length).to eq 1
    
    retry_block(attempts: 100, :sleep => 1) do |attempt|
      tasks = swarm.tasks
      running_count = 0
      tasks.each do |task|
        if (task.status == :running)
          running_count += 1
        end
      end
      puts "Waiting for tasks to start up. Count: #{running_count}"
      expect(running_count).to eq 20
      sleep 1
    end
    
    puts "Removing worker node to force service to allocate tasks all to the master ..."
    
    retry_block(attempts: 20, :sleep => 1) do |attempt|
      puts "Waiting for tasks to all relocate after removing worker node ..."
      tasks = swarm.tasks
      running_count = 0
      tasks.each do |task|
        running_count += 1 if (task.status == :running)
      end
      expect(running_count).to eq 20
    end
    service.remove()
    network.remove()
    swarm.remove()

    worker_node.remove_network(network)
  end
  
  
  describe 'Swarm creation with 2 nodes add service and cleanup everything' do
    
    it "Can add and scale service" do
      raise "Must define env variable: SWARM_MASTER_ADDRESS" if (!ENV['SWARM_MASTER_ADDRESS'])
      raise "Must define env variable: SWARM_WORKER_ADDRESS" if (!ENV['SWARM_WORKER_ADDRESS'])
      
      swarm = nil
      master_address = ENV['SWARM_MASTER_ADDRESS']
      master_ip = master_address.split("//").last.split(":").first
      worker_address = ENV['SWARM_WORKER_ADDRESS']
      worker_ip = worker_address.split("//").last.split(":").first

      master_connection = Docker::Swarm::Connection.new(master_address)
      worker_connection = Docker::Swarm::Connection.new(worker_address)

      Docker::Swarm::Swarm.leave(true, worker_connection)
      Docker::Swarm::Swarm.leave(true, master_connection)
      
      network_name = "overlay#{Time.now.to_i}"

      begin
        swarm = init_test_swarm(master_connection)
        expect(swarm.node_hash.length).to eq 1
        manager_node = swarm.manager_nodes.first
        expect(manager_node).to_not be nil
        expect(manager_node.connection).to_not be nil
        
        
        expect(swarm.connection).to eq master_connection
        read_back_swarm = Docker::Swarm::Swarm.find(master_connection)
        expect(read_back_swarm.connection).to_not be nil
    
        puts "Getting info about new swarm environment"
        read_back_swarm = Docker::Swarm::Swarm.swarm({}, master_connection)
        expect(read_back_swarm).to_not be nil
      
        nodes = swarm.nodes()
        expect(nodes.length).to eq 1
        expect(swarm.manager_nodes.length).to eq 1

        puts "Worker joining swarm"
        worker_node = swarm.join_worker(worker_connection)
        expect(worker_node.connection).to_not be nil
        expect(manager_node.connection).to_not be nil
        expect(swarm.node_hash.length).to eq 2
      
        puts "View all nodes of swarm (count should be 2)"
        nodes = swarm.nodes
        expect(nodes.length).to eq 2
        expect(swarm.manager_nodes.length).to eq 1

        network = manager_node.find_network_by_name(network_name)
        network.remove if (network)
        network = swarm.create_network_overlay(network_name)
        
        puts "Network #{network_name} subnets: #{network.subnets}"
        
        service_create_options = DEFAULT_SERVICE_SETTINGS
        service_create_options['TaskTemplate']['Env'] << "TEST_ENV=test"
        service_create_options["Mode"]["Replicated"]["Replicas"] = 5
        service_create_options["EndpointSpec"]["Ports"] = [{"Protocol" => "tcp", "PublishedPort" => 8181, "TargetPort" => 80}]
        service_create_options['Networks'] = [ {'Target' => network.id} ]

        service = swarm.create_service(service_create_options)
        
        expect(swarm.services.length).to eq 1

        # Can take a little bit of time for network to appear on service
        retry_block(attempts: 10, :sleep => 1) do |attempt|
          service = swarm.services.first
          puts "Waiting for network to appear on service"
          expect(service.network_ids).to include network.id
        end

        
        retry_block(attempts: 20, :sleep => 1) do |attempt|
          tasks = swarm.tasks
          running_count = 0
          tasks.each do |task|
            if (task.status == :running)
              running_count += 1
            end
          end
          puts "Waiting for tasks to start up.  Count: #{running_count}"
          expect(running_count).to eq 5
        end

        manager_nodes = swarm.manager_nodes
        expect(manager_nodes.length).to eq 1
      
        worker_nodes = swarm.worker_nodes
        expect(worker_nodes.length).to eq 1

        # Drain worker
        worker_node = worker_nodes.first
        worker_node.drain

        # Having consistency problems with some tasks showing error: "failed to allocate gateway (10.27.0.1): Address already in
        # use"
        # Problem is that new subnet IP is calculated to be unique on manager node, but worker nodes might have left over
        # networks that use same subnet IP.  Deleting networks through API leaves worker overlay networks in place.
        retry_block(attempts: 20, :sleep => 1) do |attempt|
          puts "Waiting for node to drain and tasks to relocate..."
          tasks = swarm.tasks
          running_count = 0
          tasks.each do |task|
            if (task.status == :running)
              expect(task.node_id).to_not eq worker_node.id
              running_count += 1
            end
          end
          expect(running_count).to eq 5
          sleep 1
        end
      
        puts "Scale service to 10 replicas"
        service.scale(10)

        retry_block(attempts: 20, :sleep => 1) do |attempt|
          puts "Waiting for tasks to scale to 10"
          tasks = swarm.tasks
          tasks.select! {|t| t.status == :running}
          expect(tasks.length).to eq 10
        end
      
        puts "Worker leaves the swarm"
        worker_node.leave
        retry_block(attempts: 20, :sleep => 1) do |attempt|
          expect(swarm.worker_nodes.length).to eq 1
          expect(swarm.worker_nodes.first.status).to eq 'down'
        end

        
        retry_block(attempts: 20, :sleep => 1) do |attempt|
          tasks = swarm.tasks
          tasks.select! {|t| t.status != :shutdown}
          puts "Tasks after worker left:"
          tasks.each do |task|
            puts " - #{task.image}  #{task.status} #{task.service.name}"
          end
          expect(tasks.length).to eq 10
        end
        
        worker_node.remove_network(network)
        worker_node.remove()
        expect(swarm.worker_nodes.length).to eq 0
      
        puts "Remove service"
        service.remove()

        retry_block(attempts: 20, :sleep => 1) do |attempt|
          tasks = swarm.tasks
          expect(tasks.length).to eq 0
        end
        network.remove()
      ensure
        if (swarm)
          puts "Removing swarm ..."
          swarm.remove 
        end
      end
      
    end
  end
end