require 'open-uri'
require 'nokogiri'

class FloorHouse
  
  # options:
  #   day: Which day to fetch (YYYY-MM-DD)

  def self.run(options = {})
    url = get_xml_url options
    return unless url # a warning report will have been filed
    
    count = 0
    failures = []
    
    xml = nil
    begin
      xml = open url
      xml = xml.read
    rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::ENETUNREACH
      Report.warning self, "Network error on fetching the floor log, can't go on."
      return
    end
    
    unless xml =~ /^<\?xml/
      Report.warning self, "No XML for that day, can't go on."
      return
    end
    
    doc = Nokogiri::XML xml
    
    
    chamber = 'house'

    # legislative_day can be reliably be taken from doc, even on a double Jan 3 session.
    # It cannot be calculated per-item from the timestamp, because chamber leadership
    # can extend legislative days to whenever they want.
    legislative_day = legislative_day_for doc
    legislative_day_stamp = legislative_day.strftime "%Y-%m-%d"

      
    (doc/:floor_action).each do |action|
      timestamp = Utils.utc_parse action.at("action_time")['for-search']
      item = action.at("action_description").inner_text.strip

      # legislative year and congress need to be calculated per-item, via timestamp.
      # They can be trusted to agree with the legislative day, as they will always
      # change on Jan 3 at 12PM EST, no matter what chamber leadership wants.
      year = Utils.current_legislative_year timestamp
      congress = Utils.congress_for_year year
      
      update = FloorUpdate.find_or_initialize_by timestamp: timestamp, chamber: chamber
      update.attributes = {
        update: item,
        congress: congress,
        year: year,
        legislative_day: legislative_day_stamp,
        bill_ids: bill_ids_for(action, item, congress),
        roll_ids: roll_ids_for(item, year),
        legislator_ids: legislator_ids_for(item)
      }
      
      if update.save
        count += 1
      else
        failures << floor_update.attributes
        puts "Failed to save floor update, will file report"
      end
      
    end
    
    if failures.any?
      Report.failure self, "Had #{failures.size} failures.", failures: failures
    end
    
    Report.success self, "Updated/created #{count} floor updates in the House."
  end
  
  def self.get_xml_url(options)
    if options[:day]
      date = Utils.utc_parse(options[:day]).strftime("%Y%m%d")
      "http://clerk.house.gov/floorsummary/Download.aspx?file=#{date}.xml"
    else
      
      html = nil
      begin
        html = open "http://clerk.house.gov/floorsummary/floor.aspx"
      rescue Timeout::Error, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::ENETUNREACH
        Report.warning self, "Network error on fetching the floor log, can't go on."
        return nil
      end
      
      doc = Nokogiri::HTML html
      
      elem = doc.css("a[title='Download Floor Proceedings in XML Format']").first
      unless elem
        Report.warning self, "Couldn't find download link, can't go on"
        return nil
      end
      
      url = elem['href']
      
      # in case they switch to absolute links
      if url =~ /^http\:\/\//
        url
      else
        "http://clerk.house.gov/floorsummary/#{url}"
      end
    end
  end
  
  def self.congress_for(doc)
    doc.at("legislative_congress")['congress'].to_i
  end
  
  def self.legislative_day_for(doc)
    Utils.utc_parse doc.at("legislative_day").text
  end
  
  def self.roll_ids_for(text, year)
    matches = text.scan(/Roll (?:no.|Call) (\d+)/i).map {|r| r.first}.uniq.compact
    matches.map {|number| "h#{number}-#{year}"}
  end
  
  def self.bill_ids_for(action, text, congress)
    matches = Utils.bill_ids_for text, congress
    
    if action_item = action.at(:action_item)
      matches << Utils.bill_code_to_id(action_item.text, congress)
    end
    
    matches.uniq
  end
  
  def self.legislator_ids_for(text)
    legislator_ids = []
    possibles = []
    
    matches = text.scan(/((M(?:rs|s|r)\.){1}\s((?:\s?[A-Z]{1}[A-Za-z-]+){0,2})(?:,\s?([A-Z]{1}[A-Za-z-]+))?(?:(?:\sof\s([A-Z]{2}))|(?:\s?\(([A-Z]{2})\)))?)/)
    
    query = {chamber: "house"}
    
    matches.each do |match|
      title = match[1]
      last_name = match[2]
      first_name = match[3]
      state = match[4] || match[5]
      
      warning = false
      
      if title == "Mr."
        query[:gender] = "M"
      else
        query[:gender] = "F"
      end
      
      if last_name.present?
        query[:last_name] = last_name
      end
      
      if state.present?
        query[:state] = state
      end
      
      legislators = Legislator.where(query).all
      if legislators.size == 0
        warning = true
      elsif legislators.size == 1
        legislator_ids << legislators.first.bioguide_id
      elsif legislators.size > 1
        query[:first_name] = first_name
        
        legislators = Legislator.where(query).all
        if legislators.size == 0
          warning = true
        elsif legislators.size  == 1
          legislator_ids << legislators.first.bioguide_id
        elsif legislators.size > 1
          legislator_ids += legislators.map(&:bioguide_id)
        end
        
      end
      
      if warning
        # occasionally non-members are actually mentioned in the floor feed, which causes a barrage of emails
        # the code here works well enough that I'm comfortable commenting these out for a while
        # Report.warning self, "Couldn't find legislator match for #{match[0]}", match: match
      end
    end
    
    legislator_ids
  end
  
end