# Shows an order's tracking: the carrier and number as plain text, and, only when Orders::TrackingLink found a public https page
# for that carrier, a link that always carries rel="noopener noreferrer nofollow". The number is escaped like any other text.
module TrackingLinkHelper
  TRACKING_REL = "noopener noreferrer nofollow".freeze

  def tracking_summary(order)
    link = Orders::TrackingLink.for(order)
    return nil unless link

    body = safe_join([ tag.strong(link.carrier), " ", tag.span(link.number, class: "shop-tracking__number") ])
    return tag.span(body, class: "shop-tracking") unless link.linked?

    safe_join([ tag.span(body, class: "shop-tracking"), " ",
                link_to("Track this parcel", link.url, class: "shop-tracking__link", target: "_blank", rel: TRACKING_REL,
                                                       "aria-label": "Track this parcel on #{link.carrier} (opens in a new tab)") ])
  end
end
