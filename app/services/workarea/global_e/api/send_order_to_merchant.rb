module Workarea
  module GlobalE
    module Api
      class SendOrderToMerchant
        attr_reader :order, :merchant_order

        def initialize(order, merchant_order)
          @order = order
          @merchant_order = merchant_order
        end

        def response
          @response ||=
            begin
              set_product_prices
              update_order
              save_shippings
              save_payment

              with_order_lock do
                raise GlobalE::UnpurchasableOrder, order.errors.full_messages.join("\n") unless @order.valid?(:purchasable)

                reservation = InventoryAdjustment.new(order).tap(&:perform)
                raise GlobalE::InsufficientInventory, reservation.errors.join("\n") if reservation.errors.present?

                capture_invetory

                Workarea::GlobalE::Merchant::ResponseInfo.new(order: order)
              end
            end
        end

        private

          def update_order
            order.update_attributes(
              global_e_id: merchant_order.order_id,
              email: shipping_details.email,
              received_from_global_e_at: Time.current
            )
          end

          def save_shippings
            Workarea::Shipping.where(order_id: order.id).destroy_all
            shipping.update_attributes(
              address: shipping_address,
              shipping_service: shipping_service,
              price_adjustments: [
                {
                  price: 'shipping',
                  amount: merchant_order.discounted_shipping_price.to_m,
                  description: shipping_service[:nmae],
                  calculator: self.class.name
                }
              ],
              global_e_price_adjustments: [
                {
                  price: 'shipping',
                  amount: merchant_order.international_details.discounted_shipping_price.to_m(merchant_order.international_details.currency_code),
                  description: shipping_service[:nmae],
                  calculator: self.class.name
                }
              ]
            )
          end

          def save_payment
            payment.set_address billing_address
          end

          # @raise [Workarea::GlobalE::InventoryCaptureFailure]
          #
          def capture_invetory
            inventory.purchase
            raise InventoryCaptureFailure, inventory.error.full_messages.join("\n") unless inventory.captured?
          end

          def set_product_prices
            merchant_order.products.each do |merchant_product|
              order_item = order.items.find merchant_product.cart_item_id

              order_item.international_total_price = merchant_product.international_discounted_price
            end
          end

          def inventory
            @inventory ||= Inventory::Transaction.from_order(
              order.id,
              order.items.inject({}) do |memo, item|
                memo[item.sku] ||= 0
                memo[item.sku] += item.quantity
                memo
              end
            )
          end

          def shipping_details
            if merchant_order.customer.is_end_customer_primary
              merchant_order.primary_shipping
            else
              merchant_order.secondary_shipping
            end
          end

          def shipping_address
            {
              first_name:           shipping_details.first_name,
              last_name:            shipping_details.last_name,
              street:               shipping_details.address1,
              street_2:             shipping_details.address2,
              city:                 shipping_details.city,
              region:               shipping_details.state_code,
              postal_code:          shipping_details.zip,
              country:              Country[shipping_details.country_code],
              phone_number:         shipping_details.phone1,
              skip_region_presence: true
            }
          end

          def shipping_service
            {
              carrier:      merchant_order.international_details.shipping_method_name,
              name:         merchant_order.international_details.shipping_method_type_name,
              service_code: merchant_order.international_details.shipping_method_code
            }
          end

          def shipping
            @shippipng ||= Shipping.create(order_id: order.id)
          end

          def billing_details
            if merchant_order.customer.is_end_customer_primary
              merchant_order.primary_billing
            else
              merchant_order.secondary_billing
            end
          end

          def billing_address
            {
              first_name:           billing_details.first_name,
              last_name:            billing_details.last_name,
              street:               billing_details.address1,
              street_2:             billing_details.address2,
              city:                 billing_details.city,
              region:               billing_details.state_code,
              postal_code:          billing_details.zip,
              country:              Country[billing_details.country_code],
              phone_number:         billing_details.phone1,
              skip_region_presence: true
            }
          end

          def payment
            @payment ||= Payment.find_or_create_by(id: order.id)
          end

          def with_order_lock
            @order.lock!
            yield
          ensure
            @order.unlock! if @order
          end
      end
    end
  end
end