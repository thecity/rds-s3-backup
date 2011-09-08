#!/usr/bin/ruby

require 'thor'
require 'fog'

class RdsS3Backup < Thor
  
  desc "s3_dump", "Runs a mysqldump from a restored snapshot of the specified RDS instance"
  method_option :rds_instance_id
  method_option :s3_bucket
  method_option :aws_access_key_id
  method_option :aws_secret_access_key
  method_option :mysql_database
  method_option :mysql_username
  method_option :mysql_password
  method_option :dump_ttl, :default => 0, :desc => "Number of old dumps to keep."
  method_option :dump_directory, :default => '/mnt/', :desc => "Where to store the temporary sql dump file."
  method_option :config_file, :desc => "YAML file of defaults for any option. Options given during execution override these."

  def s3_dump
    begin
      if options[:config_file]
        my_options = options.merge(YAML.load(File.read(options[:config_file]))) {|key, cmdopt, cfgopt| cmdopt}
      end
    rescue Exception => e
      puts "Unable to read specified configuration file #{options[:config_file]}. Reason given: #{e}"
      exit(1)
    end

    reqd_options = %w(rds_instance_id s3_bucket aws_access_key_id aws_secret_access_key mysql_database mysql_username mysql_password)
    nil_options = reqd_options.find_all{ |opt| my_options[opt].nil?}
    if nil_options.count > 0
      puts "No value provided for required option(s) #{nil_options.join(' ')} in either config file or options."
      exit(1)
    end
    
    rds        = Fog::AWS::RDS.new(:aws_access_key_id => my_options[:aws_access_key_id], 
                                   :aws_secret_access_key => my_options[:aws_secret_access_key])

    rds_server = rds.servers.get(my_options[:rds_instance_id])
    s3         = Fog::Storage.new(:provider => 'AWS', 
                                  :aws_access_key_id => my_options[:aws_access_key_id], 
                                  :aws_secret_access_key => my_options[:aws_secret_access_key], 
                                  :scheme => 'https')
    s3_bucket  = s3.directories.get(my_options[:s3_bucket])

    snap_name        = "s3-dump-snap-#{Time.now.to_i}"
    backup_server_id = "#{rds_server.id}-s3-dump-server"

    backup_file_name     = "#{rds_server.id}-mysqldump-#{Time.now.strftime('%Y-%m-%d-%H-%M-%S-%Z')}.sql.gz"
    backup_file_filepath = File.join(my_options[:dump_directory], backup_file_name)
    
    rds_server.snapshots.new(:id => snap_name).save
    new_snap = rds_server.snapshots.get(snap_name)
    new_snap.wait_for { ready? }
    new_snap.wait_for { ready? }

    rds.restore_db_instance_from_db_snapshot(new_snap.id, backup_server_id)
    backup_server = rds.servers.get(backup_server_id)
    backup_server.wait_for { ready? }
    backup_server.wait_for { ready? }

    dump_result = `/usr/local/mysql/bin/mysqldump --opt --add-drop-table --single-transaction --order-by-primary \
                  -h #{backup_server.endpoint['Address']} -u #{my_options[:mysql_username]} --password=#{my_options[:mysql_password]} \ 
                  #{my_options[:mysql_database]} | gzip --fast -c > #{backup_file_filepath} 2>&1`
    
    unless dump_result == ''
      puts "Dump failed with error #{dump_result}"
    end
    
    if s3_bucket.files.new(:key => "db_dumps/#{backup_file_name}", 
                           :body => File.open(backup_file_filepath), 
                           :acl => 'private', 
                           :content_type => 'application/x-gzip'
                           ).save
      new_snap.wait_for { ready? }
      new_snap.destroy
      
      backup_server.wait_for { ready? }
      backup_server.destroy(nil)
      
      File.unlink(backup_file_filepath)
    end
    
    if my_options[:dump_ttl] > 0
      my_files = s3_bucket.files.all('prefix' => "#{rds_server.id}-mysqldump-")
      if my_files.count > my_options[:dump_ttl]
        files_by_date = my_files.sort {|x,y| x.created_at <=> y.created_at}
        (files_by_date.count - my_options[:dump_ttl]).times do |i| 
          files_by_date[i].destroy
        end
      end
    end
  end
  
end

RdsS3Backup.start