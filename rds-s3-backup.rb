#!/usr/bin/ruby

require 'rubygems'
require 'thor'
require 'cocaine'
require 'fog'
require 'logger'


class RdsS3Backup < Thor
  
  desc "s3_dump", "Runs a mysqldump from a restored snapshot of the specified RDS instance, and uploads the dump to S3"
  method_option :rds_instance_id
  method_option :s3_bucket
  method_option :s3_prefix, :default => 'db_dumps'
  method_option :aws_access_key_id
  method_option :aws_secret_access_key
  method_option :mysql_database
  method_option :mysql_username
  method_option :mysql_password
  method_option :dump_ttl, :default => 0, :desc => "Number of old dumps to keep."
  method_option :dump_directory, :default => '/mnt/', :desc => "Where to store the temporary sql dump file."
  method_option :config_file, :desc => "YAML file of defaults for any option. Options given during execution override these."
  method_option :aws_region, :default => "us-east-1"

  def s3_dump
    my_options = build_configuration(options)
    
    rds        = Fog::AWS::RDS.new(:aws_access_key_id => my_options[:aws_access_key_id], 
                                   :aws_secret_access_key => my_options[:aws_secret_access_key],
                                   :region => my_options[:aws_region])

    rds_server = rds.servers.get(my_options[:rds_instance_id])
    s3         = Fog::Storage.new(:provider => 'AWS', 
                                  :aws_access_key_id => my_options[:aws_access_key_id], 
                                  :aws_secret_access_key => my_options[:aws_secret_access_key], 
                                  :scheme => 'https')
    s3_bucket  = s3.directories.get(my_options[:s3_bucket])

    snap_timestamp   = Time.now.strftime('%Y-%m-%d-%H-%M-%S-%Z')
    snap_name        = "s3-dump-snap-#{snap_timestamp}"
    backup_server_id = "#{rds_server.id}-s3-dump-server"

    backup_file_name     = "#{rds_server.id}-mysqldump-#{snap_timestamp}.sql.gz"
    backup_file_filepath = File.join(my_options[:dump_directory], backup_file_name)
    
    rds_server.snapshots.new(:id => snap_name).save
    new_snap = rds_server.snapshots.get(snap_name)
    new_snap.wait_for { ready? }
    new_snap.wait_for { ready? }

    rds.restore_db_instance_from_db_snapshot(new_snap.id, backup_server_id)
    backup_server = rds.servers.get(backup_server_id)
    backup_server.wait_for { ready? }
    backup_server.wait_for { ready? }

    mysqldump_command = Cocaine::CommandLine.new('mysqldump',
                                                 '--opt --add-drop-table --single-transaction --order-by-primary -h :host_address -u :mysql_username --password=:mysql_password :mysql_database | gzip --fast -c > :backup_filepath', 
                                                 :host_address    => backup_server.endpoint['Address'], 
                                                 :mysql_username  => my_options[:mysql_username], 
                                                 :mysql_password  => my_options[:mysql_password], 
                                                 :mysql_database  => my_options[:mysql_database], 
                                                 :backup_filepath => backup_file_filepath,
                                                 :logger          => Logger.new(STDOUT))
    
    begin
      mysqldump_command.run
    rescue Cocaine::ExitStatusError, Cocaine::CommandNotFoundError => e
      puts "Dump failed with error #{e.message}"
      cleanup(new_snap, backup_server, backup_file_filepath)
      exit(1)
    end
    
    tries = 1
    saved_dump = begin
      s3_bucket.files.new(:key => File.join(my_options[:s3_prefix], backup_file_name), 
                           :body => File.open(backup_file_filepath), 
                           :acl => 'private', 
                           :content_type => 'application/x-gzip'
                           ).save
      rescue Exception => e
        if tries < 3
          puts "Retrying S3 upload after #{tries} tries"
          tries += 1          
          retry
        else
          puts "Trapped exception #{e} on try #{tries}"
          false
        end
      end
      
    if saved_dump
      if my_options[:dump_ttl] > 0
       prune_dumpfiles(s3_bucket, File.join(my_options[:s3_prefix], "#{rds_server.id}-mysqldump-"), my_options[:dump_ttl])
      end   
    else
      puts "S3 upload failed!"                        
    end

    cleanup(new_snap, backup_server, backup_file_filepath)
  end
  
  no_tasks do
    def build_configuration(thor_options)
      merged_options = {}
      begin
        if options[:config_file]
          merged_options = options.merge(YAML.load(File.read(options[:config_file]))) {|key, cmdopt, cfgopt| cmdopt}
        end
      rescue Exception => e
        puts "Unable to read specified configuration file #{options[:config_file]}. Reason given: #{e}"
        exit(1)
      end

      reqd_options = %w(rds_instance_id s3_bucket aws_access_key_id aws_secret_access_key mysql_database mysql_username mysql_password)
      nil_options = reqd_options.find_all{ |opt| merged_options[opt].nil?}
      if nil_options.count > 0
        puts "No value provided for required option(s) #{nil_options.join(' ')} in either config file or options."
        exit(1)
      end
      merged_options
    end
    
    def cleanup(new_snap, backup_server, backup_file_filepath)
      new_snap.wait_for { ready? }
      new_snap.destroy
      
      backup_server.wait_for { ready? }
      backup_server.destroy(nil)
      
      File.unlink(backup_file_filepath)
    end
    
    def prune_dumpfiles(s3_bucket, backup_file_prefix, dump_ttl)
      my_files = s3_bucket.files.all('prefix' => backup_file_prefix)
      if my_files.count > dump_ttl
        files_by_date = my_files.sort {|x,y| x.last_modified <=> y.last_modified}
        (files_by_date.count - dump_ttl).times do |i| 
          files_by_date[i].destroy
        end
      end
    end
    
  end
end

RdsS3Backup.start