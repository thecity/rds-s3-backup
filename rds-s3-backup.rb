#!/usr/bin/ruby

require 'thor'
require 'fog'

class RdsS3Backup < Thor
  
  desc "s3_dump", "Runs a mysqldump from a restored snapshot of the specified RDS instance"
  method_options :rds_instance_id       => :required, 
                 :s3_bucket             => :required,
                 :aws_access_key_id     => :required,
                 :aws_secret_access_key => :required, 
                 :mysql_database        => :required, 
                 :mysql_username        => :required, 
                 :mysql_password        => :required, 
                 :dump_ttl              => 0,
                 :dump_directory        => '/mnt/'

  def s3_dump
    rds        = Fog::AWS::RDS.new(:aws_access_key_id => options[:aws_access_key_id], 
                                   :aws_secret_access_key => options[:aws_secret_access_key])

    rds_server = rds.servers.get(options[:rds_instance_id])
    s3         = Fog::Storage.new(:provider => 'AWS', 
                                  :aws_access_key_id => options[:aws_access_key_id], 
                                  :aws_secret_access_key => options[:aws_secret_access_key], 
                                  :scheme => 'https')
    s3_bucket  = s3.directories.get(options[:s3_bucket])

    snap_name        = "s3-dump-snap-#{Time.now.to_i}"
    backup_server_id = "#{rds_server.id}-s3-dump-server"

    backup_file_name     = "#{rds_server.id}-mysqldump-#{Time.now.strftime('%Y-%m-%d-%H-%M-%S-%Z')}.sql.gz"
    backup_file_filepath = File.join(options[:dump_directory], backup_file_name)
    
    rds_server.snapshots.new(:id => snap_name).save
    new_snap = rds_server.snapshots.get(snap_name)
    new_snap.wait_for { ready? }
    new_snap.wait_for { ready? }

    rds.restore_db_instance_from_db_snapshot(new_snap.id, backup_server_id)
    backup_server = rds.servers.get(backup_server_id)
    backup_server.wait_for { ready? }
    backup_server.wait_for { ready? }

    dump_result = `/usr/local/mysql/bin/mysqldump --opt --add-drop-table --single-transaction --order-by-primary \
                  -h #{backup_server.endpoint['Address']} -u #{options[:mysql_username]} --password=#{options[:mysql_password]} \ 
                  #{options[:mysql_database]} | gzip --fast -c > #{backup_file_filepath} 2>&1`
    
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
    end
    
    if options[:dump_ttl] > 0
      my_files = s3_bucket.files.all('prefix' => "#{rds_server.id}-mysqldump-")
      if my_files.count > options[:dump_ttl]
        files_by_date = my_files.sort {|x,y| x.created_at <=> y.created_at}
        (files_by_date.count - options[:dump_ttl]).times do |i| 
          files_by_date[i].destroy
        end
      end
    end
  end
  
end

RdsS3Backup.start