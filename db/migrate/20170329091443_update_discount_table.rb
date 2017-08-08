class UpdateDiscountTable < ActiveRecord::Migration[5.0]
  def self.up
    rename_column :discounts, :user, :email
  end
end
