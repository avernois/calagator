class EventsController < ApplicationController
  include SquashManyDuplicatesMixin # Provides squash_many_duplicates

  # GET /events
  # GET /events.xml
  def index
    @start_date = date_or_default_for(:start)
    @end_date = date_or_default_for(:end)

    query = Event.non_duplicates.ordered_by_ui_field(params[:order]).includes(:venue, :tags)
    @events = params[:date] ?
                query.within_dates(@start_date, @end_date) :
                query.future

    @perform_caching = params[:order].blank? && params[:date].blank?

    @page_title = t("Events")

    render_events(@events)
  end

  # GET /events/1
  # GET /events/1.xml
  def show
    begin
      @event = Event.find(params[:id])
    rescue ActiveRecord::RecordNotFound => e
      return redirect_to events_path, :flash => {:failure => e.to_s}
    end

    if @event.duplicate?
      return redirect_to(event_path(@event.duplicate_of))
    end

    @page_title = @event.title

    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render :xml  => @event.to_xml(:include => :venue) }
      format.json { render :json => @event.to_json(:include => :venue), :callback => params[:callback] }
      format.ics { ical_export([@event]) }
    end
  end

  # GET /events/new
  # GET /events/new.xml
  def new
    @event = Event.new(params[:event])
    @page_title = t("Add an Event")

    respond_to do |format|
      format.html # new.html.erb
      format.xml  { render :xml => @event }
    end
  end

  # GET /events/1/edit
  def edit
    @event = Event.find(params[:id])
    @page_title = t("Editing event", :event => @event.title)
  end

  # POST /events
  # POST /events.xml
  def create
    @event = Event.new(params[:event])
    @event.associate_with_venue(venue_ref(params))
    has_new_venue = @event.venue && @event.venue.new_record?

    @event.start_time = [ params[:start_date], params[:start_time] ]
    @event.end_time   = [ params[:end_date], params[:end_time] ]

    if evil_robot = params[:trap_field].present?
      flash[:failure] = t("message.creation.evil_robot_html")
    end

    respond_to do |format|
      if !evil_robot && params[:preview].nil? && @event.save
        flash[:success] = t("message.creation.success")
        format.html {
          if has_new_venue && !params[:venue_name].blank?
            flash[:success] += t("message.creation.more_info_venue")
            redirect_to(edit_venue_url(@event.venue, :from_event => @event.id))
          else
            redirect_to( event_path(@event) )
          end
        }
        format.xml  { render :xml => @event, :status => :created, :location => @event }
      else
        @event.valid? if params[:preview]
        format.html { render :action => "new" }
        format.xml  { render :xml => @event.errors, :status => :unprocessable_entity }
      end
    end
  end

  # PUT /events/1
  # PUT /events/1.xml
  def update
    @event = Event.find(params[:id])
    @event.associate_with_venue(venue_ref(params))
    has_new_venue = @event.venue && @event.venue.new_record?

    @event.start_time = [ params[:start_date], params[:start_time] ]
    @event.end_time   = [ params[:end_date], params[:end_time] ]

    if evil_robot = !params[:trap_field].blank?
      flash[:failure] = t("message.update.evil_robot_html")
    end

    respond_to do |format|
      if !evil_robot && params[:preview].nil? && @event.update_attributes(params[:event])
        flash[:success] = t("message.update.success")
        format.html {
          if has_new_venue && !params[:venue_name].blank?
            flash[:success] += t("message.update.more_info_venue")
            redirect_to(edit_venue_url(@event.venue, :from_event => @event.id))
          else
            redirect_to( event_path(@event) )
          end
        }
        format.xml  { head :ok }
      else
        if params[:preview]
          @event.attributes = params[:event]
          @event.valid?
          @event.tags.reload # Reload the #tags association because its members may have been modified when #tag_list was set above.
        end
        format.html { render :action => "edit" }
        format.xml  { render :xml => @event.errors, :status => :unprocessable_entity }
      end
    end
  end

  # DELETE /events/1
  # DELETE /events/1.xml
  def destroy
    @event = Event.find(params[:id])
    @event.destroy

    respond_to do |format|
      format.html { redirect_to(events_url, :flash => {:success => t("message.delete.success", :event => @event.title)}) }
      format.xml  { head :ok }
    end
  end

  # GET /events/duplicates
  def duplicates
    @type = params[:type]
    begin
      @grouped_events = Event.find_duplicates_by_type(@type)
    rescue ArgumentError => e
      @grouped_events = {}
      flash[:failure] = "#{e}"
    end

    @page_title = t("Duplicate Event Squasher")

    respond_to do |format|
      format.html # index.html.erb
      format.xml  { render :xml => @grouped_events }
    end
  end

  # Search!!!
  def search
    # TODO Refactor this method and move much of it to the record-managing
    # logic into a generalized Event::search method.

    @query = params[:query].presence
    @tag = params[:tag].presence
    @current = ["1", "true"].include?(params[:current])
    @order = params[:order].presence

    if @order && @order == "score" && @tag
      flash[:failure] = t("message.search.failure.tags_no_sort")
      @order = nil
    end

    if !@query && !@tag
      flash[:failure] = t("message.search.failure.no_query")
      return redirect_to(root_path)
    end

    if @query && @tag
      # TODO make it possible to search by tag and query simultaneously
      flash[:failure] = t("message.search.failure.query_and_tags")
      return redirect_to(root_path)
    elsif @query
      @grouped_events = Event.search_keywords_grouped_by_currentness(@query, :order => @order, :skip_old => @current)
    elsif @tag
      @grouped_events = Event.search_tag_grouped_by_currentness(@tag, :order => @order, :current => @current)
    end

    # setting @events so that we can reuse the index atom builder
    @events = @grouped_events[:past] + @grouped_events[:current]

    @page_title = @tag ? t("Events tagged with tags", :tags => @tag) : t("Search Results for query", :query => @query)

    render_events(@events)
  end

  # Display a new event form pre-filled with the contents of an existing record.
  def clone
    @event = Event.find(params[:id]).to_clone
    @page_title = t("Clone an existing Event")

    respond_to do |format|
      format.html {
        flash[:success] = t("message.clone.success")
        render "new.html.erb"
      }
      format.xml  { render :xml => @event }
    end
  end

protected

  # Export +events+ to an iCalendar file.
  def ical_export(events=nil)
    events = events || Event.future.non_duplicates
    render(:text => Event.to_ical(events, :url_helper => lambda{|event| event_url(event)}), :mime_type => 'text/calendar')
  end

  # Render +events+ for a particular format.
  def render_events(events)
    respond_to do |format|
      format.html # *.html.erb
      format.kml  # *.kml.erb
      format.ics  { ical_export(events) }
      format.atom { render :template => 'events/index' }
      format.xml  { render :xml  => events.to_xml(:include => :venue) }
      format.json { render :json => events.to_json(:include => :venue), :callback => params[:callback] }
    end
  end

  # Venues may be referred to in the params hash either by id or by name. This
  # method looks for whichever type of reference is present and returns that
  # reference. If both a venue id and a venue name are present, then the venue
  # id is returned.
  #
  # If a venue id is returned it is cast to an integer for compatibility with
  # Event#associate_with_venue.
  def venue_ref(p)
    if (p[:event] && !p[:event][:venue_id].blank?)
      p[:event][:venue_id].to_i
    else
      p[:venue_name]
    end
  end

  # Return the default start date.
  def default_start_date
    Time.zone.today
  end

  # Return the default end date.
  def default_end_date
    Time.zone.today + 3.months
  end

  # Return a date parsed from user arguments or a default date. The +kind+
  # is a value like :start, which refers to the `params[:date][+kind+]` value.
  # If there's an error, set an error message to flash.
  def date_or_default_for(kind)
    if params[:date].present?
      if params[:date].respond_to?(:has_key?)
        if params[:date].has_key?(kind)
          if params[:date][kind].present?
            begin
              return Date.parse(params[:date][kind])
            rescue ArgumentError => e
              append_flash :failure, t("message.filter.failure", :error => "an invalid", :kind => kind)
            end
          else
            append_flash :failure, t("message.filter.failure", :error => "an empty", :kind => kind)
          end
        else
          append_flash :failure, t("message.filter.failure", :error => "a missing", :kind => kind)
        end
      else
        append_flash :failure, t("message.filter.failure", :error => "a malformed", :kind => kind)
      end
    end
    return self.send("default_#{kind}_date")
  end
end
